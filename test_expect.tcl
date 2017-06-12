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
spawn tclsh8.6 morji.tcl -f :memory: -c test_init.tcl
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

# memorize
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

# tags
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
ok {deselected “all”}
send t
expect {Inactive}
expect {all}
ok {deselected “all” (verification)}
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

# import
expect {>>}
send I
expect {filename}
send test_facts.tsv\n
expect {Y}
send Y
expect {question}
expect {>>}
send { }
expect {answer}
send g
expect {question2}
send { }
expect {answer2}

# find facts
send f
expect {pattern}
send question\n
expect {1|question}
expect {fact number}
send 1\n

# exit
expect {>>}
send Q

puts "PASS"
