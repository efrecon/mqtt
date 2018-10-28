package require mqtt
package require toclbox
package require toclbox::url 0.2;   # Obfuscation

namespace eval ::smqtt {
    namespace eval vars {
        variable -keepalive  60
        variable -retransmit 5000
        variable -name       "%hostname%-%pid%-%prgname%"
        variable -clean      on
        variable -retry      "100:120000"
        variable -connected  [list]
        variable -queue      1000
        variable -cadir      ""
        variable -cafile     ""
        variable -certfile   ""
        variable -cipher     ""
        variable -dhparams   ""
        variable -keyfile    ""
        variable -password   ""
        variable -request    ""
        variable -require    ""
        variable hijacked    0
    }
    namespace export {[a-z]*}
    namespace ensemble create
}


proc ::smqtt::new { broker args } {
    # Fail early if the broker does not refer to some MQTT server
    set broker [Broker $broker]
    if { $broker eq "" } {
        return ""
    }

    # Hijack logging from mqtt to arrange for being able to catch errors at the
    # TRACE level. This relays to the toclbox logging implementation.
    if { ! $vars::hijacked } {
        proc ::mqtt::log { str } {
            toclbox debug TRACE $str
        }
        set vars::hijacked 1
    }

    set varname [toclbox::control::identifier [namespace current]::mqtt]
    upvar \#0 $varname context

    # Create a global command for accessing the mqtt connection
    set cmds [list]
    foreach cmd [info commands [namespace current]::\[a-z\]*] {
        set cmd [lindex [split $cmd :] end]
        if { $cmd ne "new" } {
            lappend cmds $cmd
        }
    }
    interp alias {} $varname {} \
        ::toclbox::control::rdispatch $varname [namespace current] $cmds

    dict set context broker $broker
    dict set context mqtt ""
    dict set context retry -1
    dict set context queue [list]
    foreach k [info vars vars::-*] {
        dict set context [lindex [split $k :] end] [set $k]
    }
    foreach {k v} $args {
        if { [dict exists $context $k] } {
            dict set context $k $v
        } else {
            toclbox debug WARN "$k is not a known option"
        }
    }

    Connect $varname
    return $varname
}


proc ::smqtt::subscribe { o subscription cmd { qos 1 } } {
    upvar \#0 $o context

    if { [dict get $context mqtt] ne "" } {
        [dict get $context mqtt] subscribe $subscription $cmd $qos
    }
}


proc ::smqtt::send { o topic data {qos 1} {retain 0} } {
    upvar \#0 $o context

    if { [dict get $context mqtt] eq "" } {
        Enqueue $o $topic $data $qos $retain
    } else {
        if { [catch {[dict get $context mqtt] publish $topic $data $qos $retain} err]} {
            toclbox debug WARN "Could not send to broker: $err"
            Enqueue $o $topic $data $qos $retain
            Connect $o 1; # Force a reconnection
        } else {
            toclbox debug DEBUG "Sent [toclbox human $data] to $topic, qos: $qos, retain: $retain"
        }
    }
}


proc ::smqtt::Enqueue { o topic data qos retain } {
    upvar \#0 $o context

    # Append to queue and truncate
    if { [dict get $context -queue] > 0 } {
        toclbox debug INFO "No/Lost connection to [::toclbox::url::obfuscate [dict get $context broker]], enqueuing for later delivery"
        set queue [dict lappend context queue $topic $data $qos $retain]
        if { [llength $queue] > 4*[dict get $context -queue] } {
            toclbox debug WARN "Max queue size [dict get $context -queue] reached, discarding old data"
            dict set context queue [lrange $queue 4 end]
            return 0
        }
        return 1
    }
    return 0
}


# Verify broker specification, automatically add mqtt:// in front if necessary.
proc ::smqtt::Broker { broker } {
    if { ![string match "mqtt://*" $broker] && ![string match "mqtts://*" $broker] } {
        if { [string first "://" $broker] < 0 } {
            toclbox debug NOTICE "No scheme specification, trying with leading mqtt://"
            set broker "mqtt://$broker"
        } else {
            toclbox debug ERROR "Broker specification [::toclbox::url::obfuscate $broker] should start with mqtt(s)"
            return ""
        }
    }
    return $broker
}


proc ::smqtt::Connect { o { force 0 } } {
    upvar \#0 $o context

    if { $force && [dict get $context mqtt] ne "" } {
        [dict get $context mqtt] disconnect
        dict set context mqtt ""
    }

    if { [dict get $context mqtt] eq "" } {
        # Split URL and decide how to connect to broker, allowing for TLS support if
        # necessary.
        set broker [::toclbox::url::split [dict get $context broker]]
        if { [dict get $broker "scheme"] eq "mqtts" } {
            set cmd [::toclbox::network::tls_socket]
            set defaultPort 8883
            # Carry on TLS specific options if non-empty, otherwise defaults
            # from the TLS implementation will be taken.
            foreach opt [list -cadir -cafile -certfile -cipher -dhparams -keyfile -password -request -require] {
                if { [dict exists $context $opt] && [dict get $context $opt] ne "" } {
                    lappend cmd $opt [dict get $context $opt]
                }
            }
            toclbox debug TRACE "Using following command for socket connection: $cmd"
        } else {
            set cmd [list socket]
            set defaultPort 1883
        }

        # Create MQTT context
        dict set context mqtt [mqtt new \
                                -username [dict get $broker "user"] \
                                -password [dict get $broker "pwd"] \
                                -socketcmd $cmd \
                                -keepalive [dict get $context -keepalive] \
                                -retransmit [dict get $context -retransmit] \
                                -clean [dict get $context -clean]]

        # Generate client name
        set cname [::toclbox::text::resolve [dict get $context -name] \
                        [list hostname [info hostname] \
                              pid [pid]]]
        set cname [string range $cname 0 22];  # Cut to MQTT max length

        # Connection Liveness. We will start subscribing to topics once we've connected
        # successfully to the broker.
        [dict get $context mqtt] subscribe \$LOCAL/connection [list [namespace current]::Liveness $o]
        [dict get $context mqtt] subscribe \$LOCAL/subscription [list [namespace current]::Liveness $o]
        [dict get $context mqtt] subscribe \$LOCAL/publication [list [namespace current]::Liveness $o]

        # Connect to remote broker
        if { [dict get $broker "port"] eq "" } {
            [dict get $context mqtt] connect $cname [dict get $broker "host"] $defaultPort
        } else {
            [dict get $context mqtt] connect $cname [dict get $broker "host"] [dict get $broker "port"]
        }
    }

    return [dict get $context mqtt]
}


proc ::smqtt::Liveness { o topic dta } {
    upvar \#0 $o context

    switch -glob -- $topic {
        "*/connection" {
            switch -- [dict get $dta state] {
                "connected" {
                    toclbox debug NOTICE "Connected to broker [::toclbox::url::obfuscate [dict get $context broker]]"
                    # If we had data on the queue, flush it
                    if { [llength [dict get $context queue]] } {
                        # Detach and empty the existing queue at once, meaning
                        # that all data will be repushed to the queue in case of
                        # problems.
                        set queue [dict get $context queue]
                        dict set context queue [list]
                        # Send all data in turns.
                        foreach { t d qos retain } {
                            send $o $t $d $qos $retain
                        }
                    }
                    if { [llength [dict get $context -connected]] } {
                        if { [catch {eval [linsert [dict get $context -connected] end $o]} err] } {
                            toclbox debug WARN "Cannot mediate about connection: $err"
                        }
                    }
                    dict set context retry -1;   # Reinitialise retry backoff
                }
                "disconnected" {
                    array set reasons {
                        0 "Normal disconnect"
                        1 "Unacceptable protocol version"
                        2 "Identifier rejected"
                        3 "Server unavailable"
                        4 "Bad user name or password"
                        5 "Not authorized"
                    }
                    if { [llength [array names reasons [dict get $dta reason]]] > 0 } {
                        toclbox debug WARN "Disconnected from broker [::toclbox::url::obfuscate [dict get $context broker]]: $reasons([dict get $dta reason])"
                    } else {
                        toclbox debug WARN "Disconnected from broker [::toclbox::url::obfuscate [dict get $context broker]], code: [dict get $dta reason]"
                    }

                    # Try to connect again to the server in a little while, this
                    # will arrange to force the creation of a whole new MQTT
                    # context and connection. The current implementation is able
                    # of exponential backoff to minimise the strain on the broker
                    if { [string first ":" [dict get $context -retry]] >= 0 } {
                        # Use the colon sign to express the minimum time to wait
                        # for reconnection, the maximum and the factor by which
                        # to multiply each time (defaults to twice)
                        lassign [split [dict get $context -retry] ":"] min max factor
                        if { $factor eq "" } { set factor 2 }
                        if { [dict get $context retry] < 0 } {
                            dict set context retry $min
                        } elseif { [dict get $context retry] > $max } {
                            dict set context retry $max
                        } else {
                            dict set context retry [expr {int([dict get $context retry]*$factor)}]
                        }
                    } else {
                        # Otherwise -retry should just be an integer. Covers for
                        # most mistakes (non-integer, empty string) through
                        # turning the feature off.
                        dict set context retry [dict get $context -retry]
                        if { [dict get $context retry] eq "" \
                                    || ![string is integer -strict [dict get $context retry]] } {
                            toclbox debug WARN "[dict get $context -retry] should be an integer or integers separated by colon signs!"
                            dict set context retry -1
                        }
                    }

                    if { [dict get $context retry] > 0 } {
                        toclbox debug NOTICE "Trying to connect again in [dict get $context retry] ms."
                        after [dict get $context retry] [list [namespace current]::Connect $o 1]
                    }
                }
            }
        }
        "*/subscription" {
            foreach {topic qos} $dta {
                switch -- $qos {
                    "" {
                        toclbox debug INFO "Unsubscribed from topic at $topic"
                    }
                    "0x80" {
                        toclbox debug INFO "Could not subscribe to topic $topic"
                    }
                    default {
                        toclbox debug INFO "Subscribed to topic $topic, QoS: $qos"
                    }
                }
            }
        }
        "*/publication" {
            toclbox debug DEBUG "Data has been published at [dict get $dta topic]"
        }
    }
}
