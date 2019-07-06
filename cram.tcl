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
    {l "" "long session (5 review rounds, 1 hour interval for last review)"}
    {r "" "short review (first presentation + 1 review round at 10 min)"}
}
set usage ": cram.tcl \[-r\] \[-l\] file"
try {
    array set params [::cmdline::getoptions argv $options $usage]
    puts [array get params]
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
    set rounds 1
} elseif {$params(l)} {
    set rounds 5
}
set study_table_path [lindex $argv 0]

sqlite3 db :memory:

db eval {
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS cards(
        uid INTEGER PRIMARY KEY,
        question TEXT NOT NULL,
        answer TEXT NOT NULL,
        reps INTEGER CHECK(reps >= 0 AND reps <= 5),
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
        LIMIT 4
    }]]
}

proc get_review_cards {} {
    global rounds
    set now [clock seconds]
    return [db eval [substcmd {
        SELECT uid FROM cards
        WHERE reps > 0 AND reps <= $rounds AND next_rep < $now
        ORDER BY next_rep
        LIMIT 50
    }]]
}

proc get_out_of_schedule_cards {} {
    global rounds
    set now [clock seconds]
    return [db eval [substcmd {
        SELECT uid FROM cards
        WHERE reps > 0 AND reps <= $rounds
        ORDER BY next_rep
        LIMIT 4
    }]]
}

proc get_card {uid} {
    return [db eval {SELECT question, answer, reps, next_rep from cards WHERE uid=$uid}]
}

proc interval {rep} {
    global rounds
    if {$rounds == 1 && $rep == 0} {
        return 600
    }
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
    next_card
}

proc update_forgotten_card {} {
    global cur_card_uid
    db eval {UPDATE cards SET reps=0 WHERE uid=$cur_card_uid}
    db eval {UPDATE cards SET next_rep=0 WHERE uid=$cur_card_uid}
    next_card
}

set cur_card_uid 0
set cur_hand {}
set last_mode {}
set showed_answer 0

proc next_card {} {
    global cur_hand last_mode cur_card_uid question answer showed_answer
    if {!([llength $cur_hand] > 0)} {
        if {$last_mode eq "learning"} {
            set cur_hand [get_review_cards]
            if {[llength $cur_hand] > 0} {
                set last_mode "reviewing"
            }
        }
        if {[llength $cur_hand] == 0} {
            set cur_hand [get_new_cards]
            if {[llength $cur_hand] > 0} {
                set last_mode "learning"
            } else {
                set cur_hand [get_review_cards]
                set last_mode "reviewing"
            }
        }
        if {[llength $cur_hand] == 0} {
            set cur_hand [get_out_of_schedule_cards]
            if {[llength $cur_hand] > 1} {
                # avoid showing the same card twice in a row
                set cur_hand [lreplace $cur_hand 0 1 [lindex $cur_hand 1] [lindex $cur_hand 0]]
            }
            if {[llength $cur_hand] > 3} {
                # some sane shuffling when out of schedule
                set cur_hand [lreplace $cur_hand 2 3 [lindex $cur_hand 3] [lindex $cur_hand 2]]
            }
            set last_mode "reviewing"
        }
        puts "New hand with [llength $cur_hand] cards"
    }
    if {[llength $cur_hand] > 0} {
        set cur_card_uid [lindex $cur_hand 0]
        show_question
        set showed_answer 0
        set cur_hand [lrange $cur_hand 1 end]
    } else {
        puts "Finished reviewing!"
        exit 0
    }
}

proc show_question {} {
    global cur_card_uid question answer
    lassign [get_card $cur_card_uid] q a reps next_rep
    puts "Card $cur_card_uid reps $reps next_rep $next_rep"
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
    set answer {}
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
    global study_table_path
    set fh [open $study_table_path]
    set content [read $fh]
    close $fh
    set lines [split $content \n]
    set lnum 0
    set ncards 0
    foreach line $lines {
        incr lnum
        if {$line eq ""} {
            continue
        }
        set fields [split $line \t]
        if {[llength $fields] != 2} {
            error "$file:$lnum: incorrect number of fields: [llength $fields] (should be 2)"
        }
        lassign $fields q a
        if {$q eq ""} {
            warn "$file:$lnum: empty question"
        }
        if {$a eq ""} {
            warn "$file:$lnum: empty answer"
        }
        try {
            db eval {INSERT INTO cards(question, answer, reps, next_rep) VALUES($q, $a, 0, 0)}
            incr ncards
        } on error {msg} {
            error "$file:$lnum: $msg"
        }
    }
    puts "Studying $ncards cards."
    next_card
}

wm title . "Cram Tk"
wm geometry . =800x640
font create QuestionFont -size 84
#option add *font QuestionFont
font create AnswerFont -size 42
#option add *font AnswerFont
set question {}
set answer {}
grid [label .q -textvariable question -font QuestionFont -fg {#b58900}] -sticky ews
grid [label .a -textvariable answer -font AnswerFont -fg {#268bd2}] -sticky new
grid rowconfigure . .q -weight 1 -uniform group1
grid rowconfigure . .a -weight 1 -uniform group1
grid columnconfigure . .q -weight 1
within_transaction {initialize}
bind . Q {
    puts "See you later!"  
    exit
}
bind . g { within_transaction {if {$showed_answer == 1} {update_recalled_card}} }
bind . a { within_transaction {update_forgotten_card} }
bind . <space> { within_transaction {show_answer} }
