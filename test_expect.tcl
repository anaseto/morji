package require Expect

set log 0
proc ok {msg} {
    global log
    if {!$log} {
        puts $msg
    }
}

set env(EDITOR) ./test_editor.tcl

log_user $log
spawn tclsh8.6 morji.tcl :memory:
expect {>>}
send ?
expect {quit program}
ok help
expect {>>}
send s
expect {*0 0 0 0*}
ok {week schedule}
expect {>>}
send S
expect {Unseen cards}
expect {Memorized cards}
ok statistics

# new cards
expect {>>}
send N
#expect {Warning}
#expect {Error}
expect {>>}
ok new_card
send ?
expect Keys
ok new_card_help
expect {>>}
send a
expect {>>}
ok again
send q
expect {Tags:}
expect {mytag}
ok {show tags}
expect {Question:}
expect {question}
ok {show question}
send { }
expect {answer}
expect {>>}
ok {show answer}
send E
expect {Y/n}
send Y
ok confirm
expect {>>}
send S
expect {Unseen cards}
expect {1}
expect {Cards not memorized}
expect {1}
expect {Memorized cards}
expect {0}
expect {>>}
ok {statistics 1 unseen}
send g
expect {>>}
ok {grade good}
send S
expect {Unseen cards}
expect {0}
expect {Cards not memorized}
expect {0}
expect {Memorized cards}
expect {1}
expect {>>}
ok {statistics 1 memorized}
send s
expect {1 0}
ok {1 scheduled card}

expect {>>}
send t
expect {Inactive}
expect {+tag>>}
ok {deselect tags}
send \n
expect {>>}
send T
expect {Active}
expect {all}
expect {mytag}
expect {tag>>}
ok {select tags}
send all\n
expect {>>}
send t
expect {Inactive}
expect {all}
ok {deselected “all”}
send \n
expect {>>}
# exit
send Q

puts "OK"
