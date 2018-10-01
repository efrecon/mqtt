# MQTT Client

This repository provides a slightly modified version of this excellent mqtt
[implementation][mqtt], together with a higher-level wrapper. The wrapper
requires [toclbox] to function properly. This documentation focuses mainly on
the wrapper as the underlying library is documentated on the and original site.

  [mqtt]: https://chiselapp.com/user/schelte/repository/mqtt
  [toclbox]: https://github.com/efrecon/toclbox 

## Differences from the original MQTT implementation

This library provides a new option to the main `mqtt` command called
`-socketcmd`. This command will be used to open the connection to the remote
MQTT broker and is meant to facilitate use of [TLS] for securing connections.
By default, `-socketcmd` is set to `socket`, thus providing the same behaviour
as the original implementation. The command can instead be set to an invokation
of `::tls::socket` making it easy to open connection to TLS-secured MQTT
brokers, usually running on port `8883`.

  [TLS]: https://tcltls.rkeene.org/

## High-Level Wrapper

The module `smqtt` (S as in "Simple") aims at providing a simple wrapper around
the low-level MQTT implementation with the following added functionality:

* Automatic reconnection (exponential backoff) to the broker.
* Client naming interface to benefit from persistent sessions.
* Message enqueuing during connection losses sessions.
* Logging

`smqtt` is implemented as an ensemble, providing a single top-level sub-command
called `new`. The command will return an identifier that can be used to access
the remaining of the API. The recommended programming style for accessing the
library is thus the following:

```Tcl
package require smqtt
set c [smqtt new test.mosquitto.org]; # Open connection to mosquitto test broker
$c send mytest "some data";           # Send data to test topic
```

However, the following would achieve the same:

```Tcl
package require smqtt
set c [smqtt new test.mosquitto.org]; # Open connection to mosquitto test broker
smqtt send $c mytest "some data";     # Send data to test topic
```

The different sub-commands of the `smqtt` command are described below.

### new

The sub-command `new` will establish a persistent connection to an MQTT broker.
The command takes a URL to the broker and a number of dash-led options and their
values as argument. No path will be interpreted in the URL passed as a parameter
and TLS secured connections will automatically make use of the TLS library if
present.  The leading `mqtt:` (default) or `mqtts:` scheme are used to
differentiate access via TLS. In other words, the two following invokations
would open an unencrypted connection to the mosquitto
[test](http://test.mosquitto.org) server:

```Tcl
set c [smqtt new test.mosquitto.org]
set c [smqtt new mqtt://test.mosquitto.org:1883]
```

And, provided that `mosquitto.org.crt` points to the certificate authority for
[file](http://test.mosquitto.org/ssl/mosquitto.org.crt) for the mosquitto
server, the following command would open en encrypted connection to the same
server:

```Tcl
set c [smqtt new mqtts://test.mosquitto.org -cafile ./mosquitto.org.crt]
```

Authentication information at the MQTT broker can be provided as part of the
URL, as in the following (non-working, since no such user exist!) example:

```Tcl
set c [smqtt new mqtt://user:secret@test.mosquitto.org]
```

In addition to the URL specifying the broker to connect to, the sub-command
takes the following dash-led options:

#### `-keepalive`

Number of seconds for keep-alive handshakes to the server, defaults to 60
seconds.

#### `-name`

Client identifier to use when connecting to the server. This is not to be
confused with the username for authentication, which should be specified as part
of the URL instead. The name will automatically be truncated to the first 23
characters, as per the specification. In the name, a number of `%` enclosed
token strings will be dynamically replaced by their values at run-time.
Particular to `smqtt` are the following ones:

* `%hostname%` the hostname on which the client connection is starting.
* `%pid%` the process identifier at which the client connection is opened.
* `%prgname%` the main name of the program (script) at which the connection is
  opened.

A number of remaining `%`-enclosed tokens are provided by `toclbox`, these are
all keys of the [tcl_platform] array and all environment variables accessible to
the script.

  [tcl_platform]: https://www.tcl.tk/man/tcl/TclCmd/tclvars.htm#M24

#### `-clean`

The value of this option should be a boolean and will tell whether to open a
clean connection or not. The default is to open a clean connection.

#### `-retry`

The value of this option is either a single integer or two or three integers
separated by a colon `:` sign. When an integer, it specifies how long to wait
(in milliseconds) before reconnecting to the server. A negative value will
completely turn off the feature. When two or three integers separated by a colon
sign are used, these express the minimum, maximum and multiplication factor for
the exponential backoff reconnection time. Starting from the minimum, the
reconnection algorithm will wait and then multiply by the factor (defaulting to
`2`) until it reconnects. It will not wait more that the maximum specified
number of milliseconds.

Upon reconnection, `smqtt` will automatically re-subscribe to all topics that
were subscribed to using `subscribe` (see below).

#### `-connected`

This is a connection callback and the command, if not empty will be called each
time a new (re)connection is established with the broker. The identifier of the
`smqtt` object will be passed as the last argument to the command.

#### `-queue`

This should be an integer and the maximum number of messages to enqueue while
disconnected from the server. A negative number supporesses enqueuing mechanisms
entirely.

#### `-cadir`, `-cafile`, `-certfile`, `-cipher`, `-dhparams`, `-keyfile`, `-password`, `-request`, `-require`

When present and non-empty the value of this option and the option itself will
automatically be passed to the TLS library for establishing socket connection.
The default for all these options is an empty value, meaning to not specify the
value at all and rely on the [defaults] from the library.  Note that `-request`
and `-require` really are boolean if you need to specify them.

Pay specific attention that the option named `-password` is used to specify the
password when opening TLS key files, but not the password for the MQTT
authentication. The MQTT password should be specified as part as the URL used
for the connection.

  [defaults]: https://core.tcl.tk/tcltls/wiki?name=Documentation#tls::import

### `subscribe`

This command takes the following arguments:

* The topic(s) to subscribe to. This specification can use wildcards as per the
  MQTT specification.
* A command to callback each time data matching the topic subscription has been
  received. The command will be called with the topic at which data was received
  followed by the data itself.
* An optional QoS value, `0`, `1` or `2`, which defaults to `1`.

This library arranges for the subscriptions to resist losses of connection,
meaning that the set of a topic subscriptions for a given broker will be kept
across reconnection, when these occur.

### `send`

Send data to a given topic, this command takes the following arguments:

* The topic to send the data to
* The data to be sent
* An optional QoS value, `0`, `1` or `2`, which defaults to `1`.
* An optional retaining value, a boolean that defaults to `0`.