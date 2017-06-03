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
spawn tclsh8.6 morji.tcl -f :memory:
expect {No cards to review}
expect {>>}
send ?
expect {quit program}
ok help
expect {>>}
send s
expect {w/m/y}
ok {week schedule prompt}
send w
expect {*0 0 0 0}
ok {week schedule}
expect {>>}
send S
expect {Cards not memorized}
expect {Memorized cards}
ok statistics

# new cards
expect {>>}
send N
#expect {Warning}
#expect {Error}
expect {Question}
expect {question}
expect {answer}
expect {Notes}
expect {notes}
expect {Type}
expect {oneside}
expect {Tags}
expect {mytag}
expect {>>}
ok new_card
send ?
expect Keys
ok new_card_help
expect {>>}
send a
expect {Memorize 1 new card}
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
expect {Cards not memorized}
expect {1}
expect {Memorized cards}
expect {0}
expect {Cards memorized today}
expect {0}
expect {>>}
ok {statistics 1 unseen}
send g
expect {>>}
ok {grade good}
send S
expect {Cards not memorized}
expect {0}
expect {Memorized cards}
expect {1}
expect {Cards memorized today}
expect {1}
expect {>>}
ok {statistics 1 memorized}
send s
send w
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
send r
expect {tag to rename}
send mytag\n
expect {new tag name}
send mynewtag\n
send T
expect {mynewtag}
send \n

# exit
expect {>>}
send Q

puts "OK"
