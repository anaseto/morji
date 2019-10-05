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
#
# Key bindings: down (show answer) left (forgotten card) right (recalled card) Q (quit)

package require Tk
package require sqlite3
package require cmdline

set options {
    {i "invert question/answer fields"}
    {l "long session (5 review rounds, instead of 4 rounds)"}
    {r "new cards in random order"}
    {S "smaller font"}
    {t "test session (no extra reviews, unless forgotten)"}
    {w "write forgotten cards to file ('cram-forgotten-cards-' as name prefix)"}
}
set usage ": tclsh8.6 cram.tcl \[options\] file"
try {
    array set params [::cmdline::getoptions argv $options $usage]
} trap {CMDLINE USAGE} {msg} {
    puts stderr "$msg"
    exit 1
}
if {[llength $argv] != 1} {
    puts stderr "cram: tclsh8.6 cram.tcl \[options\] file"
    exit 1
}
set rounds 4
if {$params(t)} {
    puts "Test session"
} elseif {$params(l)} {
    puts "Long learning session"
    set rounds 5
} else {
    puts "Normal learning session"
}
if {$params(r)} {
    puts "New cards in random order"
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
        next_rep INTEGER CHECK(next_rep >= 0),
        forgotten INTEGER
    );
    CREATE INDEX IF NOT EXISTS cards_idx1 ON cards(reps);
    CREATE INDEX IF NOT EXISTS cards_idx2 ON cards(next_rep);
    CREATE INDEX IF NOT EXISTS cards_idx3 ON cards(reps,next_rep);
}

proc substcmd {text} {
    uplevel "subst -nobackslashes -novariables {$text}"
}

proc get_new_cards {} {
    global params
    if {$params(r)} {
        set order random()
    } else {
        set order uid
    }
    return [db eval [substcmd {
        SELECT uid FROM cards
        WHERE reps == 0
        ORDER BY [set order]
        LIMIT 2
    }]]
}

proc get_review_cards {} {
    global params rounds
    if {$params(r)} {
        set order "reps, next_rep, random()"
    } else {
        set order "reps, next_rep"
    }
    set now [clock seconds]
    return [db eval [substcmd {
        SELECT uid FROM cards
        WHERE reps > 0 AND reps <= $rounds AND next_rep < $now
        ORDER BY [set order]
        LIMIT 2
    }]]
}

proc get_out_of_schedule_cards {} {
    global rounds
    return [db eval {
        SELECT uid FROM cards
        WHERE reps > 0 AND reps <= $rounds
        ORDER BY next_rep
        LIMIT 2
    }]
}

proc get_card {uid} {
    return [db eval {
        SELECT question, answer, reps, next_rep FROM cards
        WHERE uid=$uid
    }]
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

proc card_set {set_code} {
    uplevel "db eval {UPDATE cards SET $set_code WHERE uid=\$cur_card_uid}"
}

proc next_card_pause {} {
    global nc_pause question answer 
    set question {}
    set answer {}
    after 1000 set nc_pause 0
    vwait nc_pause
}

proc update_recalled_card {} {
    global cur_card_uid
    lassign [get_card $cur_card_uid] q a reps next_rep
    set next_rep [clock add [clock seconds] [interval $reps] seconds]
    incr reps
    card_set {reps=$reps}
    card_set {next_rep=$next_rep}
    puts "Card $cur_card_uid: reps $reps next_rep [clock format $next_rep -format {%H:%M:%S}]"
    next_card_pause
    next_card
}

proc update_forgotten_card {} {
    global cur_card_uid
    set reps [get_reps $cur_card_uid]
    if {$reps == 0} {
        update_recalled_card
        return
    }
    card_set {reps=0}
    card_set {next_rep=0}
    card_set {forgotten=forgotten+1}
    puts "Card $cur_card_uid: again"
    next_card_pause
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
        write_forgotten
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
        set mins [expr {
            entier(($next_rep - $now) / 60)
        }]
        set seconds [expr {
            ($next_rep - $now) - 60 * $mins
        }]
        set nr [clock format $next_rep -format {%H:%M:%S}]
        set rtime "Take a break until $nr ($mins minutes $seconds seconds)"
        .q configure -fg {#839496}
        set question "☺"
        set now [clock seconds]
        after 1000 set force_oos 0
        vwait force_oos
    }
    set rtime {}
    set oos_break 0
    # violet yellow red cyan magenta green orange
    set colors {
        {#6c71c4}
        {#b58900}
        {#dc322f}
        {#2aa198}
        {#d33682}
        {#859900}
        {#cb4b16}
    }
    set c [expr { $cur_card_uid % [llength $colors] }]
    set fg [lindex $colors $c]
    .q configure -fg $fg
    set question $q
}

proc show_answer {} {
    global cur_card_uid answer showed_answer ans_pause
    lassign [get_card $cur_card_uid] q a reps next_rep
    after 250 set ans_pause 0
    vwait ans_pause
    set answer $a
    set showed_answer 1
}

proc within_transaction {script} {
    db transaction {uplevel $script}
}

proc initialize {} {
    global study_table_path rounds params
    if {![file readable $study_table_path]} {
        puts stderr "cram: cannot read file $study_table_path"
        exit 1
    }
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
            puts stderr "cram: $study_table_path: $lnum: incorrect number of fields: [llength $fields] (expected 2 tab-separated columns)"
            exit 1
        }
        lassign $fields q a
        if {$q eq ""} {
            warn "cram: $study_table_path:$lnum: empty question"
        }
        if {$a eq ""} {
            warn "cram: $study_table_path:$lnum: empty answer"
        }
        set irep 0
        set itime 0
        if {$params(t)} {
            set irep 4
        }
        if {$params(i)} {
            lassign [list $q $a] a q
        }
        try {
            db eval {
                INSERT INTO cards(question, answer, reps, next_rep, forgotten)
                VALUES($q, $a, $irep, $itime, 0)
            }
        } on error {msg} {
            error "cram: $study_table_path:$lnum: $msg"
        }
        incr ncards
    }
    puts "Number of cards: $ncards"
    next_card
}

proc write_forgotten {} {
    global study_table_path params
    if {!$params(w)} {
        return
    }
    set fh [open "cram-forgotten-cards-${study_table_path}" w]
    db eval {
        SELECT question, answer FROM cards
        WHERE forgotten > 0
        ORDER BY forgotten DESC
    } {
        puts $fh "$question\t$answer"
    }
    close $fh
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
if {$params(S)} {
    font create AnswerFont -size 24
} else {
    font create AnswerFont -size $fontsize
}
#option add *font AnswerFont
set rtime {}
set question {}
set answer {}
grid [label .rtime -textvariable rtime -font TimeFont -fg {#839496}] -sticky ew
grid [label .q -textvariable question -font QuestionFont -fg {#b58900}] -sticky ews
grid [label .a -textvariable answer -font AnswerFont -fg {#839496}] -sticky new
grid rowconfigure . .rtime -weight 1 -uniform group1
grid rowconfigure . .q -weight 10 -uniform group1
grid rowconfigure . .a -weight 10 -uniform group1
grid columnconfigure . .rtime -weight 1
within_transaction initialize
bind . Q {
    puts "See you later!"  
    write_forgotten
    exit
}
bind . <Right> {
    within_transaction {
        if {$showed_answer == 1} update_recalled_card
    }
}
bind . <Left> {
    within_transaction {
        if {$showed_answer == 1} update_forgotten_card
    }
}
bind . <Down> {
    within_transaction {
        if {$::oos_break} {
            set ::force_oos 1
        } else {
            show_answer
        }
    }
}
bind . <Key-F1> {
    tk_messageBox -message "Help" -detail "Key bindings:\n- down (show answer)\n- left (forgotten card)\n- right (recalled card)\n- Q (quit)" -type ok -icon info
}
