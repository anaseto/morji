#!/usr/bin/env tclsh8.6
# Copyright (c) 2019 Yon <anaseto@bardinflor.perso.aquilenet.fr>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

package require Tk
package require sqlite3
package require cmdline

set options {
    {i "invert question/answer fields"}
    {l "long session (5 review rounds, 1 hour interval for last review)"}
    {r "short review (first presentation + 1 review round at 10 min)"}
    {R "new cards in random order"}
    {S "sentences"}
    {t "test review (one presentation unless forgotten)"}
}
set usage ": cram.tcl \[-i\] \[-r\] \[-l\] \[-S\] file"
try {
    array set params [::cmdline::getoptions argv $options $usage]
} trap {CMDLINE USAGE} {msg} {
    puts stderr "Usage: $msg"
    exit 1
}
if {[llength $argv] != 1} {
    puts stderr "Usage: $usage"
    exit 1
}
set rounds 4
if {$params(r)} {
    puts "Short review"
} elseif {$params(t)} {
    puts "Test review"
} elseif {$params(l)} {
    puts "Long session"
    set rounds 5
} else {
    puts "Normal session"
}
if {$params(R)} {
    puts "Random order"
}
set study_table_path [lindex $argv 0]

sqlite3 db :memory:

db eval {
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS cards(
        uid INTEGER PRIMARY KEY,
        question TEXT NOT NULL,
        answer TEXT NOT NULL,
        reps INTEGER CHECK(reps >= 0 AND reps <= 6),
        next_rep INTEGER CHECK(next_rep >= 0)
    );
    CREATE INDEX IF NOT EXISTS cards_idx1 ON cards(reps);
    CREATE INDEX IF NOT EXISTS cards_idx2 ON cards(next_rep);
    CREATE INDEX IF NOT EXISTS cards_idx3 ON cards(reps,next_rep);
}

proc substcmd {text} {
    return [subst -nobackslashes -novariables $text]
}

proc get_new_cards {} {
    return [db eval [substcmd {
        SELECT uid FROM cards
        WHERE reps == 0
        ORDER BY uid
        LIMIT 2
    }]]
}

if {$params(R)} {
    proc get_new_cards {} {
        return [db eval [substcmd {
            SELECT uid FROM cards
            WHERE reps == 0
            ORDER BY random()
            LIMIT 2
        }]]
    }
}

proc get_review_cards {} {
    global rounds
    set now [clock seconds]
    return [db eval [substcmd {
        SELECT uid FROM cards
        WHERE reps > 0 AND reps <= $rounds AND next_rep < $now
        ORDER BY next_rep
        LIMIT 2
    }]]
}

if {$params(R)} {
    proc get_review_cards {} {
        global rounds
        set now [clock seconds]
        return [db eval [substcmd {
            SELECT uid FROM cards
            WHERE reps > 0 AND reps <= $rounds AND next_rep < $now
            ORDER BY next_rep, random()
            LIMIT 2
        }]]
    }
}

proc get_out_of_schedule_cards {} {
    global rounds
    return [db eval [substcmd {
        SELECT uid FROM cards
        WHERE reps > 0 AND reps <= $rounds
        ORDER BY next_rep
        LIMIT 2
    }]]
}

proc get_card {uid} {
    return [db eval {SELECT question, answer, reps, next_rep FROM cards WHERE uid=$uid}]
}

proc get_reps {uid} {
    return [db onecolumn {SELECT reps FROM cards WHERE uid=$uid}]
}

proc interval {rep} {
    switch $rep {
        0   { return 5 }
        1   { return 25 }
        2   { return 120 }
        3   { return 600 }
        4   { return 3600 }
        default   { return 999999 }
    }
}
proc update_recalled_card {} {
    global cur_card_uid
    lassign [get_card $cur_card_uid] question answer reps next_rep
    set next_rep [clock add [clock seconds] [interval $reps] seconds]
    incr reps
    db eval {UPDATE cards SET reps=$reps WHERE uid=$cur_card_uid}
    db eval {UPDATE cards SET next_rep=$next_rep WHERE uid=$cur_card_uid}
    puts "Card $cur_card_uid: reps $reps next_rep [clock format $next_rep -format {%H:%M:%S}]"
    next_card
}

proc update_forgotten_card {} {
    global cur_card_uid
    set reps [get_reps $cur_card_uid]
    if {$reps == 0} {
        update_recalled_card
        return
    }
    db eval {UPDATE cards SET reps=0 WHERE uid=$cur_card_uid}
    db eval {UPDATE cards SET next_rep=0 WHERE uid=$cur_card_uid}
    puts "Card $cur_card_uid: again"
    next_card
}

set cur_card_uid 0
set cur_hand {}
set last_mode {}
set showed_answer 0
set force_oos 0
set oos_break 0

proc next_card {} {
    global cur_hand last_mode cur_card_uid question answer showed_answer prev_card_uid
    if {!([llength $cur_hand] > 0)} {
        if {$last_mode eq "learning"} {
            set cur_hand [get_review_cards]
            if {[llength $cur_hand] > 0} {
                set last_mode "reviewing"
            }
        }
        if {[llength $cur_hand] == 0} {
            set review_cards [get_review_cards]
            if {[llength $review_cards] == 0} {
                set cur_hand [get_new_cards]
            } else {
                set reps [get_reps [lindex $review_cards 0]]
                set now [clock seconds]
                if {$reps > 2} {
                    set cur_hand [get_new_cards]
                }
            }
            if {[llength $cur_hand] > 0} {
                set last_mode "learning"
            } else {
                set cur_hand $review_cards
                set last_mode "reviewing"
            }
        }
        if {[llength $cur_hand] == 0} {
            set cur_hand [get_out_of_schedule_cards]
            set last_mode "reviewing"
        }
        puts "New hand with [llength $cur_hand] cards"
    }
    if {[llength $cur_hand] > 0} {
        set prev_card_uid $cur_card_uid
        set cur_card_uid [lindex $cur_hand 0]
        if {$cur_card_uid == $prev_card_uid} {
            if {[llength $cur_hand] > 1} {
                # avoid showing the same card twice in a row
                set cur_hand [lreplace $cur_hand 0 1 [lindex $cur_hand 1] [lindex $cur_hand 0]]
            }
            set cur_card_uid [lindex $cur_hand 0]
        }
        show_question
        set showed_answer 0
        set cur_hand [lrange $cur_hand 1 end]
    } else {
        puts "Finished reviewing!"
        exit 0
    }
}

proc show_question {} {
    global cur_card_uid question answer rtime force_oos oos_break
    set now [clock seconds]
    lassign [get_card $cur_card_uid] q a reps next_rep
    set answer {}
    while {$now < $next_rep} {
        set oos_break 1
        if {$force_oos == 1} {
            set force_oos 0
            break
        }
        set mins [expr {entier(($next_rep - $now) / 60)}]
        set seconds [expr {($next_rep - $now) - 60 * $mins}]
        set rtime "Take a break until [clock format $next_rep -format {%H:%M:%S}] ($mins minutes $seconds seconds)"
        .q configure -fg {#839496}
        set question "☺"
        set now [clock seconds]
        after 1000 set force_oos 0
        vwait force_oos
    }
    set rtime {}
    #if {($now > $next_rep) && $reps > 0} {
        #set mins [expr {entier(($now - $next_rep) / 60)}]
        #set seconds [expr {($now - $next_rep) - 60 * $mins}]
        #set rtime "late ($mins minutes $seconds seconds)"
    #}
    set oos_break 0
    set c [expr {$cur_card_uid % 7}]
    set fg {#b58900}
    # violet yellow red cyan magenta green orange
    switch $c {
        0 {set fg {#6c71c4}}
        1 {set fg {#b58900}}
        2 {set fg {#dc322f}}
        3 {set fg {#2aa198}}
        4 {set fg {#d33682}}
        5 {set fg {#859900}}
        6 {set fg {#cb4b16}}
    }
    .q configure -fg $fg
    set question $q
}

proc show_answer {} {
    global cur_card_uid answer showed_answer
    lassign [get_card $cur_card_uid] q a reps next_rep
    set answer $a
    set showed_answer 1
}

proc within_transaction {script} {
    db transaction {uplevel $script}
}

proc initialize {} {
    global study_table_path rounds params
    set fh [open $study_table_path]
    set content [read $fh]
    close $fh
    set lines [split $content \n]
    set lnum 0
    set ncards 0
    set itime [clock seconds]
    foreach line $lines {
        incr lnum
        if {$line eq ""} {
            continue
        }
        set fields [split $line \t]
        if {[llength $fields] != 2} {
            error "$study_table_path:$lnum: incorrect number of fields: [llength $fields] (should be 2)"
        }
        lassign $fields q a
        if {$q eq ""} {
            warn "$study_table_path:$lnum: empty question"
        }
        if {$a eq ""} {
            warn "$study_table_path:$lnum: empty answer"
        }
        try {
            set irep 0
            set itime 0
            if {$params(r)} {
                set irep 3
            } elseif {$params(t)} {
                set irep 4
            }
            if {$params(i)} {
                lassign [list $q $a] a q
            }
            db eval {INSERT INTO cards(question, answer, reps, next_rep) VALUES($q, $a, $irep, $itime)}
            incr ncards
        } on error {msg} {
            error "$study_table_path:$lnum: $msg"
        }
    }
    puts "Studying $ncards cards."
    next_card
}

wm title . "Cram Tk"
wm geometry . =800x640
set fontsize 42
if {$params(S)} {
    set fontsize 18
    option add *wrapLength [expr {56 * $fontsize}]
}
font create TimeFont -size 12
font create QuestionFont -size [expr {$fontsize * 2}]
#option add *font QuestionFont
font create AnswerFont -size $fontsize
#option add *font AnswerFont
set rtime {}
set question {}
set answer {}
grid [label .rtime -textvariable rtime -font TimeFont -fg {#839496}] -sticky ew
grid [label .q -textvariable question -font QuestionFont -fg {#b58900}] -sticky ews
grid [label .a -textvariable answer -font AnswerFont -fg {#268bd2}] -sticky new
grid rowconfigure . .rtime -weight 1 -uniform group1
grid rowconfigure . .q -weight 10 -uniform group1
grid rowconfigure . .a -weight 10 -uniform group1
grid columnconfigure . .rtime -weight 1
within_transaction {initialize}
bind . Q {
    puts "See you later!"  
    exit
}
bind . <Right> { within_transaction {if {$showed_answer == 1} {update_recalled_card}} }
bind . <Left> { within_transaction {if {$showed_answer == 1} {update_forgotten_card}} }
bind . <Down> {
    within_transaction {
        if {$::oos_break} {
            set ::force_oos 1
        } else {
            show_answer
        }
    }
}
