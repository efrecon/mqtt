package ifneeded mqtt 1.2 [subst {
    source [file join $dir mqtt.tcl]
    package provide mqtt 1.2
}]
package ifneeded smqtt 0.2 [subst {
    source [file join $dir smqtt.tcl]
    package provide smqtt 0.2
}]
