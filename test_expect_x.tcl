package require Expect

set log 0
proc ok {msg} {
    global log
    if {!$log} {
        puts "ok - $msg"
    }
}

set env(EDITOR) ./test_editor.tcl

log_user $log
spawn tclsh8.6 morji.tcl -f :memory: -c test_init.tcl -x test_x_script.tcl
expect {Y}
puts PASS
