package require sqlite3
package require term::ansi::ctrl::unix
package require term::ansi::send
package require textutil
::term::ansi::send::import

######################### globals ################ 

proc init_globals {} {
    sqlite3 db :memory:
    #sqlite3 db /tmp/morji_test.db

    db eval {
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS cards(
            uid INTEGER PRIMARY KEY,
            -- last repetition time (null for new cards)
            last_rep INTEGER,
            -- next repetition time (null for new cards)
            next_rep INTEGER CHECK(next_rep ISNULL OR last_rep < next_rep),
            easyness REAL NOT NULL DEFAULT 2.5 CHECK(easyness >= 1.3),
            -- number of repetitions (0 for new and forgotten cards)
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
            -- simple/voc(recognition/production)/cloze...
            type TEXT NOT NULL
        )
    }

    set ::START_TIME [clock seconds]
    set ::FIRST_ACTION_FOR_CARD 1
    set ::ANSWER_ALREADY_SEEN 0
}

######################### managing facts ################ 

proc add_fact {question answer notes type {tags {}}} {
    db eval {INSERT INTO facts(question, answer, notes, type) VALUES($question, $answer, $notes, $type)}
    set fact_uid [db last_insert_rowid]
    switch $type {
        "simple" {
            db eval {INSERT INTO cards(reps, fact_uid, fact_data)
                 VALUES(0, $fact_uid, "")}
        }
        "voc" {
            foreach fact_data {R P} {
                db eval {INSERT INTO cards(reps, fact_uid, fact_data)
                     VALUES(0, $fact_uid, $fact_data)}
            }
        }
        default {
            error "invalid type: $type"
        }
    }
    set tag_uids {}
    lappend tags all
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
    if {($type eq "simple") && ($otype eq "voc")} {
        db eval {UPDATE cards SET fact_data = 'R' WHERE fact_uid = $fact_uid}
        db eval {INSERT INTO cards(reps, fact_uid, fact_data) VALUES(0, $fact_uid, 'P')}
    } elseif {($type eq "voc") && ($otype eq "simple")} {
        db eval {DELETE FROM cards WHERE fact_uid=$fact_uid AND fact_data = 'P'}
        db eval {UPDATE cards SET fact_data = '' WHERE fact_uid=$fact_uid}
    } elseif {($type ne $otype)} {
        warn "card of type $otype cannot become of type $type"
    }
    if {$type ni {simple voc cloze}} {
        warn "invalid type: $type"
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
        if {$tag eq "all"} {
            continue
        }
        if {!($tag in $otags)} {
            set uid [db onecolumn {SELECT uid FROM tags WHERE name=$tag}]
            if {$uid eq ""} {
                db eval {INSERT INTO tags(name) VALUES($tag)}
                set uid [db last_insert_rowid]
            }
            db eval {INSERT INTO fact_tags VALUES($fact_uid, $uid)}
        }
    }
    # removed tags 
    foreach tag $otags {
        if {$tag eq "all"} {
            continue
        }
        if {!($tag in $tags)} {
            set uid [db onecolumn {SELECT uid FROM tags WHERE name=$tag}]
            if {$uid eq ""} {
                error "internal error: update_tags_for_fact: tag without uid"
            }
            db eval {DELETE FROM fact_tags WHERE fact_uid=$fact_uid AND tag_uid=$uid}
        }
    }
}

proc delete_tag {tag} {
    # XXX: unused
    db eval {DELETE FROM tags WHERE name=$tag}
}

proc delete_fact {uid} {
    # XXX: unused
    db eval {DELETE FROM facts WHERE uid=$uid}
}

######################### getting cards and fact data ################ 

proc start_of_day {} {
    set fmt %d/%m/%y
    return [clock add [clock scan [clock format $::START_TIME -format $fmt] -format $fmt] 2 hours]
}

proc get_cards_where_clause {} {
    return {
        EXISTS(SELECT 1 FROM tags, fact_tags, facts
            WHERE cards.fact_uid = facts.uid
            AND tags.uid = fact_tags.tag_uid
            AND facts.uid = fact_tags.fact_uid
            AND tags.active = 1)
    }
}

proc get_today_cards {} {
    set tomorrow [clock add [start_of_day] 1 day]
    return [db eval [string cat {
        SELECT cards.uid FROM cards
        WHERE next_rep < $tomorrow
        AND reps > 0 AND
    } [get_cards_where_clause] {
        ORDER BY next_rep - last_rep
    }]]
}

proc get_forgotten_cards {} {
    set tomorrow [clock add [start_of_day] 1 day]
    return [db eval [string cat {
        SELECT cards.uid FROM cards
        WHERE next_rep < $tomorrow
        AND reps = 0 AND
    } [get_cards_where_clause] {
        ORDER BY next_rep - last_rep
        LIMIT 15
    }]]
}

proc get_new_cards {} {
    return [db eval [string cat {
        SELECT cards.uid FROM cards
        WHERE cards.next_rep ISNULL AND
    } [get_cards_where_clause] {
        LIMIT 5
    }]]
}

proc get_card_user_info {uid} {
    return [db eval {
        SELECT facts.question, facts.answer, facts.notes, facts.type, cards.fact_data
        FROM cards, facts
        WHERE cards.uid=$uid AND facts.uid = cards.fact_uid
    }]
}

proc get_fact_user_info {uid} {
    return [db eval {
        SELECT facts.question, facts.answer, facts.notes, facts.type
        FROM facts
        WHERE facts.uid=$uid
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

######################### tag functions ################ 

proc get_active_tags {} {
    return [db eval {SELECT name FROM tags WHERE active = 1}]
}

proc get_inactive_tags {} {
    return [db eval {SELECT name FROM tags WHERE active = 0}]
}

proc select_tags {pattern} {
    db eval {UPDATE tags SET active = 1 WHERE name GLOB $pattern}
}

proc deselect_tags {pattern} {
    db eval {UPDATE tags SET active = 0 WHERE name GLOB $pattern}
}

######################### scheduling ################ 

proc schedule_card {uid grade} {
    db eval {SELECT last_rep, next_rep, easyness, reps FROM cards WHERE uid=$uid} {
        # only grades 0, 2, 4 and 5 are possible
        if {(($reps == 0) && ($grade < 2))} {
            break
        }
        set easyness [expr {$easyness + (0.1 - (5.0-$grade)*(0.08 + (5.0-$grade)*0.02))}]
        if {$easyness < 1.3} {
            set easyness 1.3
        }
        if {$grade >= 2} {
            set new_last_rep $::START_TIME
            set new_next_rep $new_last_rep
            incr reps
        } else {
            set new_last_rep $last_rep
            set new_next_rep $next_rep
            set reps 0
        }
        # TODO: add some randomness and late revision tweaks
        switch $reps {
            0 { }
            1 { set new_next_rep [clock add $new_next_rep 1 day] }
            2 { set new_next_rep [clock add $new_next_rep 6 day] }
            default {
                set interval [expr {int(($new_last_rep-$last_rep)*$easyness)}]
                set new_next_rep [clock add $new_next_rep $interval seconds]
            }
        }
        db eval {
            UPDATE cards
            SET last_rep=$new_last_rep, next_rep=$new_next_rep, easyness=$easyness, reps=$reps
            WHERE uid=$uid
        }
        break
    }
    return "scheduled"
}

######################### fact parsing ################ 

proc check_field {field_contents field} {
    if {[dict get $field_contents $field] ne ""} {
        warn "double use of $field"
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
                if {$current_field ne ""} {
                    dict set field_contents $current_field [string trim $field]
                } elseif {[regexp {\S} $field]} {
                    warn "wandering text outside field: “$field”"
                }
            }
        }
    }
    return [dict values $field_contents]
}

######################### IO stuff ################ 

proc get_key {prompt} {
    with_color blue {
        puts -nonewline "$prompt "
        flush stdout
    }
    ::term::ansi::ctrl::unix::raw
    set key [read stdin 1]
    ::term::ansi::ctrl::unix::cooked
    puts $key
    return $key
}

proc get_line {prompt} {
    with_color blue {
        puts -nonewline "$prompt "
        flush stdout
    }
    return [gets stdin]
}

proc draw_line {} {
    # XXX: not used
    puts [string repeat ─ [::term::ansi::ctrl::unix::columns]]
}

proc put_help {} {
    put_header "Keys (on current card)" cyan

    puts {
  q      show current card question again
  space  show current card answer
  a      grade card as not memorized (again)
  h      grade card recall as hard
  g      grade card recall as good
  e      grade card recall as easy
  E      edit current card (if any)
  D      delete current card}
    put_context_independent_keys
}

proc put_context_independent_help {} {
    put_context_independent_keys
}

proc put_context_independent_keys {} {
    put_header "Keys" cyan
    puts {
  ?      show this help
  N      new card
  t      select tags with glob pattern
  T      deselect tags with glob pattern
  Q      quit program}
}

proc put_header {title {color yellow}} {
    with_color $color {
        puts -nonewline "$title: "
        flush stdout
    }
}

proc put_question {question answer type fact_data} {
    put_header "Question"
    switch $type {
        simple { puts $question }
        voc {
            if {$fact_data eq "R"} {
                puts $question
            } else {
                puts $answer
            }
        }
    }
}

proc put_tags {type tags} {
    put_header "Tags" yellow
    puts $tags
}

proc put_answer {question answer notes type fact_data} {
    put_header "Answer"
    switch $type {
        simple { puts $answer }
        voc {
            if {$fact_data eq "R"} {
                puts $answer
            } else {
                puts $question
            }
        }
    }
    if {[regexp {\S} $notes]} {
        put_header "Notes"
        puts $notes
    }
}

proc edit_card {tmp tmpfile fact_uid} {
    set editor $::env(EDITOR)
    if {$editor eq ""} {
        set editor vim
    }
    exec $editor [file normalize $tmpfile] <@stdin >@stdout 2>@stderr
    lassign [parse_card [read $tmp]] question answer notes type tags
    set tags [textutil::splitx $tags]
    set tags [lsearch -inline -all -not -exact $tags all]
    set tags [lsort -unique $tags]
    if {$fact_uid ne ""} {
        update_fact $fact_uid $question $answer $notes $type $tags
    } else {
        add_fact $question $answer $notes $type $tags
    }
    lassign [get_fact_user_info $fact_uid] question answer notes type
    foreach {f t} [list $question Question $answer Answer $notes Notes $type Type $tags Tags] {
        put_header "$t"
        puts $f
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
    set tags [lsearch -inline -all -not -exact $tags all]
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

proc warn {msg} {
    with_color red {
        puts stderr "Warning: $msg"
    }
}

proc show_info {msg} {
    with_color cyan {
        puts stderr "Info: $msg"
    }
}

proc with_color {color script} {
    send::sda_fg$color
    try { 
        uplevel $script
    } finally {
        send::sda_fgdefault
    }
}

proc put_info {phase n} {
    switch $phase {
        get_today_cards { show_info "Review $n memorized cards." }
        get_forgotten_cards { show_info "Review $n forgotten cards." }
        get_new_cards { show_info "Memorize $n new cards." }
    }
}

######################### main loop stuff ################

proc prompt_delete_card {uid} {
    set key [get_key {Delete card? [Y/n] >>}]
    if {$key eq "Y"} {
        db eval {DELETE FROM cards WHERE uid=$uid}
        return restart
    }
}

proc card_prompt {card_uid} {
    lassign [get_card_user_info $card_uid] question answer notes type fact_data
    if {$::FIRST_ACTION_FOR_CARD} {
        draw_line
        put_tags $type [get_card_tags $card_uid]
        put_question $question $answer $type $fact_data
    }
    set key [get_key ">>"]
    switch $key {
        q { 
            put_tags $type [get_card_tags $card_uid]
            put_question $question $answer $type $fact_data;
            return
        }
        " " { 
            put_answer $question $answer $notes $type $fact_data
            set ::ANSWER_ALREADY_SEEN 1
            return
        }
        E { edit_existent_card $card_uid; return }
        ? { put_help; return }
        D { return [prompt_delete_card $card_uid] }
        a - h - g - e {
            if {!$::ANSWER_ALREADY_SEEN} {
                error "you must see the answer before grading the card"
            }
        }
    }

    set ret [handle_base_key $key]
    if {$ret ne ""} {
        return $ret
    }

    if {$::ANSWER_ALREADY_SEEN} {
        switch $key {
            r { return [schedule_card $card_uid 0] }
            h { return [schedule_card $card_uid 2] }
            g { return [schedule_card $card_uid 4] }
            e { return [schedule_card $card_uid 5] }
        }
    }
    error "invalid key: $key (type ? for help)"
}

proc no_card_prompt {} {
    set key [get_key ">>"]
    set ret [handle_base_key $key]
    if {$ret ne ""} {
        return $ret
    }

    error "invalid key: $key (type ? for help)"
}

proc handle_base_key {key} {
    switch $key {
        t {
            put_header "Inactive Tags"
            puts [get_inactive_tags]
            set line [get_line "+tag>>"]
            select_tags $line
            return restart
        }
        T {
            put_header "Active Tags"
            puts [get_active_tags]
            set line [get_line "-tag>>"]
            deselect_tags $line
            return restart
        }
        N { edit_new_card; return restart }
        Q { puts ""; return quit }
        ? { put_context_independent_help; return 1 }
    }
}

proc action_with_context {script} {
    set ret ""
    try {
        set ret [db transaction {uplevel $script}]
    } on error {msg} {
        with_color red {
            puts stderr "Error: $msg"
        }
    } finally {
        return $ret
    }
}

proc run {} {
    set found_cards 0
    foreach f {get_today_cards get_forgotten_cards get_new_cards} {
        set cards [db transaction {$f}]
        if {[llength $cards] > 0} {
            set found_cards 1
            set n [llength $cards]
        }
        foreach card $cards {
            send::clear
            puts "Type ? for help."
            put_info $f $n
            incr n -1
            set ret ""
            set ::FIRST_ACTION_FOR_CARD 1
            set ::ANSWER_ALREADY_SEEN 0
            while {$ret ne "scheduled"} {
                set ret [action_with_context {card_prompt $card}]
                set ::FIRST_ACTION_FOR_CARD 0
                switch $ret {
                    quit { quit }
                    restart { tailcall run }
                }
            }
        }
    }
    if {$found_cards} {
        tailcall run
    }
    if {$::TEST} {
        tailcall test_go_to_next_day
    } else {
        send::clear
        puts "Type ? for help."
        show_info "No cards to review nor new cards"
        set ret ""
        while {1} {
            set ret [action_with_context {no_card_prompt}]
            switch $ret {
                quit { quit }
                restart { tailcall run }
            }
        }
    }
}

proc main {} {
    try {
        run
    } on error {result} {
        with_color red {
            puts stderr "Fatal Error: $result"
        }
    } finally {
        quit
    }
}

proc quit {} {
    db close
    exit
}

if {!([info exists TEST] && $TEST)} {
    set TEST 0
    init_globals
    main
}
