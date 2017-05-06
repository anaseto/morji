package require sqlite3
package require term::ansi::ctrl::unix
package require term::ansi::send
package require textutil

sqlite3 db :memory:

db eval {
    PRAGMA foreign_keys = ON;
    CREATE TABLE IF NOT EXISTS cards(
        uid INTEGER PRIMARY KEY,

        last_rep INTEGER,
        next_rep INTEGER,
        easyness REAL NOT NULL,
        reps INTEGER NOT NULL,

        fact_uid INTEGER NOT NULL REFERENCES facts ON DELETE CASCADE,
        -- additional data whose meaning depends on facts.type
        fact_data TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS cards_idx2 ON cards(fact_uid);
    CREATE TABLE IF NOT EXISTS tags(
        uid INTEGER PRIMARY KEY,
        name TEXT UNIQUE NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS tags_idx ON tags(name);
    CREATE TABLE IF NOT EXISTS fact_tags(
        fact_uid INTEGER NOT NULL REFERENCES facts ON DELETE CASCADE,
        tag_uid INTEGER NOT NULL REFERENCES tags ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS fact_tags_idx1 ON fact_tags(fact_uid);
    CREATE INDEX IF NOT EXISTS fact_tags_idx2 ON fact_tags(tag_uid);
    CREATE TABLE IF NOT EXISTS facts(
        uid INTEGER PRIMARY KEY,
        question TEXT NOT NULL,
        answer TEXT NOT NULL,
        notes TEXT NOT NULL,
        -- simple/vocabulary(recognition/production)/cloze...
        type TEXT NOT NULL
    )
}

set START_TIME [clock seconds]

######################### managing facts ################ 

proc add_fact {question answer notes type {tags {}}} {
    db eval {INSERT INTO facts(question, answer, notes, type) VALUES($question, $answer, $notes, $type)}
    set fact_uid [db last_insert_rowid]
    switch $type {
        "simple" {
            db eval {INSERT INTO cards(easyness, reps, fact_uid, fact_data)
                 VALUES(2.5, 0, $fact_uid, "")}
        }
        "voc" {
            foreach fact_data {R P} {
                db eval {INSERT INTO cards(easyness, reps, fact_uid, fact_data)
                     VALUES(2.5, 0, $fact_uid, $fact_data)}
            }
        }
        default {
            error "invalid type: $type"
        }
    }
    set tag_uids {}
    lappend tags _all
    foreach tag $tags {
        db eval {INSERT OR IGNORE INTO tags(name) VALUES($tag)}
        lappend tag_uids [db eval {SELECT uid FROM tags WHERE name=$tag}]
    }
    foreach uid [lsort -unique $tag_uids] {
        db eval {INSERT INTO fact_tags VALUES($fact_uid, $uid)}
    }
}

proc update_fact {fact_uid question answer notes type tags} {
    set otype [db eval {SELECT type FROM facts WHERE uid=$fact_uid}]
    db eval {UPDATE facts SET question=$question, answer=$answer, notes=$notes WHERE uid=$fact_uid}
    if {[string equal $type simple] && [string equal $otype voc] } {
        db eval {UPDATE cards SET fact_data = 'R' WHERE fact_uid = $fact_uid}
        db eval {INSERT INTO cards(easyness, reps, fact_uid, fact_data) VALUES(2.5, 0, $fact_uid, 'P')}
    } elseif {[string equal $type voc] && [string equal $otype simple] } {
        db eval {DELETE FROM cards WHERE fact_uid=$fact_uid AND fact_data = 'P'}
        db eval {UPDATE cards SET fact_data = '' WHERE fact_uid=$fact_uid}
    }
    update_tags_for_fact $fact_uid $tags
}

proc update_tags_for_fact {fact_uid tags} {
    set otags [db eval {
        SELECT name FROM tags
        WHERE EXISTS(SELECT 1 FROM fact_tags WHERE fact_uid=$fact_uid AND tag_uid = tags.uid)
    }]
    # new tags
    foreach tag $tags {
        if {[string equal $tag _all]} {
            continue
        }
        if {[lsearch -exact $otags $tag] < 0} {
            set uid [db onecolumn {SELECT uid FROM tags WHERE name=$tag}]
            if {[string equal $uid ""]} {
                db eval {INSERT INTO tags(name) VALUES($tag)}
                set uid [db last_insert_rowid]
            }
            db eval {INSERT INTO fact_tags VALUES($fact_uid, $uid)}
        }
    }
    # removed tags 
    foreach tag $otags {
        if {[string equal $tag _all]} {
            continue
        }
        if {[lsearch -exact $tags $tag] < 0} {
            set uid [db onecolumn {SELECT uid FROM tags WHERE name=$tag}]
            if {[string equal $uid ""]} {
                error "internal error: update_tags_for_fact: tag without uid"
            }
            db eval {DELETE FROM fact_tags WHERE fact_uid=$fact_uid AND tag_uid=$uid)}
        }
    }
}

proc create_tag {tag} {
    db eval {INSERT INTO tags(name, active) VALUES($tag, 1)}
}

proc delete_tag {tag} {
    db eval {DELETE FROM tags WHERE name=$tag}
}

proc delete_fact {uid} {
    db eval {DELETE FROM facts WHERE uid=$uid}
}

proc activate_tag {tag {active 1}} {
    db eval {UPDATE tags SET active=$active WHERE tag=$tag}
}

######################### getting cards ################ 

proc start_of_day {} {
    set fmt %d/%m/%y
    return [clock add [clock scan [clock format $::START_TIME -format $fmt] -format $fmt] 2 hours]
}

set GET_CARDS_WHERE_CLAUSE {
    cards.fact_uid = facts.uid
    AND facts.uid = fact_tags.fact_uid
    AND (EXISTS(SELECT 1 FROM tags WHERE tags.name = '_all' AND tags.active = 1)
        OR EXISTS(SELECT 1 WHERE tags.uid = fact_tags.tag_uid AND tags.active = 1))
}

proc get_today_cards {} {
    set tomorrow [clock add [start_of_day] 1 day]
    return [db eval [string cat {
        SELECT cards.uid FROM cards, tags, fact_tags, facts
        WHERE next_rep < $tomorrow AND
        reps > 0 AND
    } $::GET_CARDS_WHERE_CLAUSE {
        ORDER BY next_rep - last_rep
    }]]
}

proc get_forgotten_cards {} {
    set tomorrow [clock add [start_of_day] 1 day]
    return [db eval [string cat {
        SELECT cards.uid FROM cards, tags, fact_tags, facts
        WHERE next_rep < $tomorrow AND
        reps = 0 AND
    } $::GET_CARDS_WHERE_CLAUSE {
        ORDER BY next_rep - last_rep
    }]]
}

proc get_new_cards {} {
    return [db eval [string cat {
        SELECT cards.uid FROM cards, tags, fact_tags, facts
        WHERE cards.next_rep ISNULL AND
    } $::GET_CARDS_WHERE_CLAUSE]]
}

proc get_card_user_info {uid} {
    return [db eval {
        SELECT facts.question, facts.answer, facts.notes, facts.type
        FROM cards, facts
        WHERE cards.uid=$uid AND facts.uid = cards.fact_uid
    }]
}

proc get_card_tags {uid} {
    return [db eval {
        SELECT name FROM tags
        WHERE EXISTS(
            SELECT 1 FROM cards, fact_tags
            WHERE cards.uid=$uid
            AND fact_tags.fact_uid = cards.fact_uid
            AND tag_uid = tags.uid)
    }]
}

######################### scheduling ################ 

proc schedule_card {uid grade} {
    db eval {SELECT last_rep, next_rep, easyness, reps FROM cards WHERE uid=$uid} {
        set easyness [expr {$easyness + (0.1 - (5.0-$grade)*(0.08 + (5.0-$grade)*0.02))}]
        set new_last_rep $::START_TIME
        set new_next_rep $new_last_rep
        incr reps
        if {[string equal $grade 0]} {
            set reps 0
        }
        # TODO: add some randomness and late revision tweaks
        # TODO: do not update easyness if new card and grade 0
        switch $reps {
            0 { }
            1 { set new_next_rep [clock add $new_next_rep 1 day] }
            2 { set new_next_rep [clock add $new_next_rep 6 day] }
            default {
                set new_next_rep [clock add $new_next_rep [expr {($new_last_rep-$last_rep)*$easyness}] seconds]
            }
        }
        db eval {
            UPDATE cards
            SET last_rep=$new_last_rep, next_rep=$new_next_rep, easyness=$easyness, reps=$reps
            WHERE uid=$uid}
        break
    }
    return "scheduled"
}

######################### fact parsing ################ 

proc check_field {field_contents field} {
    if {![string equal [dict get $field_contents $field] ""]} {
        puts stderr "warning: double use of $field"
    }
}

proc parse_card {text} {
    set fields [textutil::splitx $text {(\\(?:Question|Answer|Notes|Type|Tags):)}]
    set field_contents [dict create]
    set current_field ""
    foreach f {{\Question:} {\Answer:} {\Notes:} {\Type:} {\Tags:}} { dict set field_contents $f "" }
    foreach field $fields {
        switch $field {
            {\Question:} - {\Answer:} - {\Notes:} - {\Type:} - {\Tags:} {
                check_field $field_contents $field
                set current_field $field
            }
            default {
                if {![string equal $current_field ""]} {
                    dict set field_contents $current_field [string trim $field]
                } elseif {[regexp {\S+} $field]}  {
                    puts stderr "wandering text outside field: “$field”"
                }
            }
        }
    }
    return [dict values $field_contents]
}

######################### IO stuff ################ 

proc help {} {
    ::term::ansi::send::sda_fggreen
    puts -nonewline Help:
    ::term::ansi::send::sda_fgdefault

    puts {
  ? show this help
  q show question
  a show answer
  r repeat card
  h hard card
  g good card
  e easy card
  N new card
  E edit card
  Q quit program
    }   
}

proc draw_line {} {
    puts [string repeat ─ [::term::ansi::ctrl::unix::columns]]
}

proc draw_title_line {title} {
    ::term::ansi::send::sda_fgyellow
    puts -nonewline "$title: "
    flush stdout
    ::term::ansi::send::sda_fgdefault
}

proc get_key {} {
    ::term::ansi::send::sda_fgblue
    puts -nonewline ">> "
    flush stdout
    ::term::ansi::send::sda_fgdefault
    ::term::ansi::ctrl::unix::raw
    set key [read stdin 1]
    ::term::ansi::ctrl::unix::cooked
    puts $key
    return $key
}

proc put_question {question} {
    draw_title_line "Question"
    puts $question
}

proc put_answer {answer} {
    draw_title_line "Answer"
    puts $answer
}

proc edit_card {tmp tmpfile fact_uid} {
    set editor $::env(EDITOR)
    if {[string equal $editor ""]} {
        set editor vim
    }
    exec $editor [file normalize $tmpfile] <@stdin >@stdout 2>@stderr
    set content [read $tmp]
    lassign [parse_card $content] question answer notes type tags
    foreach {f t} [list $question Question $answer Answer $notes Notes $type Type $tags Tags] {
        draw_title_line "$t"
        puts $f
    }
    set tags [textutil::splitx $tags]
    if {![string equal $fact_uid ""]} {
        update_fact $fact_uid $question $answer $notes $type $tags
    } else {
        add_fact $question $answer $notes $type $tags
    }
}

proc edit_new_card {} {
    set tmp [file tempfile tmpfile]
    puts $tmp "\\Question: "
    puts $tmp "\\Answer: "
    puts $tmp "\\Notes: "
    puts $tmp "\\Type: "
    puts $tmp "\\Tags: "
    flush $tmp
    seek $tmp 0
    edit_card $tmp $tmpfile ""
    close $tmp
    file delete $tmpfile
}

proc edit_existent_card {card_uid} {
    set tmp [file tempfile tmpfile]
    lassign [get_card_user_info $card_uid] question answer notes type
    set tags [get_card_tags $card_uid]
    set tags [lsearch -inline -all -not -exact $tags _all]
    puts $tmp "\\Question: $question"
    puts $tmp "\\Answer: $answer"
    puts $tmp "\\Notes: $notes"
    puts $tmp "\\Type: $type"
    puts $tmp "\\Tags: $tags"
    flush $tmp
    seek $tmp 0
    db eval {SELECT fact_uid FROM cards WHERE uid=$card_uid} break
    edit_card $tmp $tmpfile $fact_uid
    close $tmp
    file delete $tmpfile
}

######################### main loop stuff ################

proc ask_for_card {card_uid} {
    lassign [get_card_user_info $card_uid] question answer
    switch [get_key] {
        q { put_question $question }
        a { put_answer $answer }
        r { return [schedule_card $card_uid 0] }
        h { return [schedule_card $card_uid 2] }
        g { return [schedule_card $card_uid 4] }
        e { return [schedule_card $card_uid 5] }
        N { edit_new_card }
        E { edit_existent_card $card_uid }
        ? { help }
        Q { puts ""; return quit }
        default { 
            ::term::ansi::send::sda_fgred
            puts "Error: unknown key"
            ::term::ansi::send::sda_fgdefault
        }
    }
    return
}

proc run {} {
    puts "Type ? for help."
    foreach f {get_today_cards get_forgotten_cards get_new_cards} {
        set cards [db transaction {$f}]
        foreach card $cards {
            set ret ""
            while {![string equal $ret "scheduled"]} {
                if {[catch { set ret [db transaction {ask_for_card $card}] } err_msg]} {
                    ::term::ansi::send::sda_fgred
                    puts stderr "Error: $err_msg"
                    ::term::ansi::send::sda_fgdefault
                }
                switch $ret {
                    quit { quit }
                }
            }
        }
    }
    quit
}

proc quit {} {
    db close
    exit
}

######################### testing ################ 

proc test_review_new {} {
    set START_TIME [clock add $::START_TIME 1 day]
    set card_uids [get_today_cards]
    set i 0
    foreach card $card_uids {
        incr i
        foreach f [get_card_user_info $card] {
            #puts "review: $card $f"
        }
    }
    set card_uids [get_new_cards]
    foreach card $card_uids {
        incr i
        foreach f [get_card_user_info $card] {
            #puts "new: $card $f"
        }
    }
    #puts $i
}

proc test {} {
    create_tag _all
    set i 0
    while {$i<3} {
        db transaction {
            add_fact question$i answer$i extras simple
        }
        incr i
    }
    set i 0
    while {$i < 3} {
        db transaction {
            add_fact question$i answer$i extras voc
        }
        incr i
    }
    db transaction {
        schedule_card 1 4
    }
    #puts [db eval {
        #SELECT cards.uid from cards
        #WHERE EXISTS(SELECT 1 FROM tags WHERE tags.name = '_all' AND tags.active = 1)
        #OR EXISTS(SELECT 1 FROM tags WHERE 
            #tags.active = 1
            #AND tags
    #}]
    test_review_new
    db eval {SELECT * FROM tags} tags {
        #parray tags
        #puts ""
    }
    #ask_for_card 2
    run
    #db eval {SELECT * FROM facts} facts {
        #parray facts
        #puts ""
    #}

}

test
