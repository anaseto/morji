package require sqlite3
package require term::ansi::ctrl::unix
package require term::ansi::send
package require term::ansi::code::ctrl
package require textutil

# TODO: backups, more tests, recuperar db mnemosyne

######################### namespace state ################ 

namespace eval morji {
    ::term::ansi::send::import
    proc variables {args} {
        foreach arg $args {
            uplevel [list variable $arg]
        }
    }

    variables START_TIME FIRST_ACTION_FOR_CARD ANSWER_ALREADY_SEEN TEST
    namespace eval markup {
        # index of current card's cloze
        variable CLOZE 0
    }

    namespace eval config {}
}


proc morji::init_state {{dbfile :memory:}} {
    variables START_TIME
    sqlite3 db $dbfile

    db eval {
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS cards(
            uid INTEGER PRIMARY KEY,
            -- last repetition time (null for new cards)
            last_rep INTEGER,
            -- next repetition time (null for new cards)
            next_rep INTEGER CHECK(next_rep ISNULL OR last_rep < next_rep),
            easiness REAL NOT NULL DEFAULT 2.5 CHECK(easiness > 1.29),
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
        CREATE INDEX IF NOT EXISTS tags_idx1 ON tags(name);
        CREATE INDEX IF NOT EXISTS tags_idx2 ON tags(active);
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
            -- oneside/twoside(recognition/production)/cloze...
            type TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS misc_info(
            key TEXT NOT NULL PRIMARY KEY,
            value TEXT
        )
    }

    set START_TIME [clock seconds]
}

######################### managing facts ################ 

proc morji::add_fact {question answer notes type {tags {}}} {
    db eval {INSERT INTO facts(question, answer, notes, type) VALUES($question, $answer, $notes, $type)}
    set fact_uid [db last_insert_rowid]
    switch $type {
        oneside {
            add_card $fact_uid
        }
        twoside {
            foreach fact_data {R P} {
                add_card $fact_uid $fact_data
            }
        }
        cloze {
            set i 0
            foreach elt [get_clozes $question] {
                set cmd [string range $elt 1 end-1]
                check_cloze_cmd $cmd
                set fact_data [list $i {*}[lrange $cmd 1 end]]
                add_card $fact_uid $fact_data
                incr i
            }
        }
        default {
            error "invalid type: $type"
        }
    }
    lappend tags all
    set tag_uids [lmap tag $tags {
        db eval {INSERT OR IGNORE INTO tags(name) VALUES($tag)}
        db eval {SELECT uid FROM tags WHERE name=$tag}
    }]
    foreach uid [lsort -unique $tag_uids] {
        db eval {INSERT INTO fact_tags VALUES($fact_uid, $uid)}
    }
    return $fact_uid
}

proc morji::add_card {fact_uid {fact_data {}}} {
    db eval {
        INSERT INTO cards(reps, fact_uid, fact_data)
        VALUES(0, $fact_uid, $fact_data)
    }
}

proc morji::update_fact {fact_uid question answer notes type tags} {
    set otype [db eval {SELECT type FROM facts WHERE uid=$fact_uid}]
    if {$otype ni {oneside twoside cloze}} {
        error "internal error: invalid otype: $otype"
    }
    db eval {UPDATE facts SET question=$question, answer=$answer, notes=$notes WHERE uid=$fact_uid}
    if {($otype eq "oneside") && ($type eq "twoside")} {
        db eval {UPDATE cards SET fact_data = 'R' WHERE fact_uid = $fact_uid}
        db eval {UPDATE facts SET type=$type WHERE uid=$fact_uid}
        add_card $fact_uid "P"
    } elseif {($otype eq "twoside") && ($type eq "oneside")} {
        db eval {DELETE FROM cards WHERE fact_uid=$fact_uid AND fact_data = 'P'}
        db eval {UPDATE facts SET type=$type WHERE uid=$fact_uid}
        db eval {UPDATE cards SET fact_data = '' WHERE fact_uid=$fact_uid}
    } elseif {($type ne $otype)} {
        warn "card of type $otype cannot become of type $type"
    }
    if {($otype eq "cloze")} {
        update_cloze_fact $fact_uid $question
    }
    if {$type ni {oneside twoside cloze}} {
        warn "invalid type: $type"
    }
    update_tags_for_fact $fact_uid $tags
}

proc morji::update_cloze_fact {fact_uid question} {
    set ocards [db eval {SELECT uid, fact_data FROM cards WHERE cards.fact_uid=$fact_uid}]
    set nclozes {}
    set i 0
    foreach elt [get_clozes $question] {
        set cmd [string range $elt 1 end-1]
        check_cloze_cmd $cmd
        lappend nclozes [list $i {*}[lrange $cmd 1 end]]
        incr i
    }
    if {[llength $ocards] == 2 * [llength $nclozes]} {
        # TODO: add more heuristics?
        foreach {uid ocloze} $ocards {
            set ncloze [lindex $nclozes [lindex $ocloze 0]]
            db eval {UPDATE cards SET fact_data=$ncloze WHERE uid=$uid}
        }
        return
    }
    set nclozes_first [lmap cloze $nclozes {lindex $cloze 1}]
    foreach {uid ocloze} $ocards {
        set found [lsearch -exact $nclozes_first [lindex $ocloze 1]]
        if {$found > -1} {
            set ncloze [lindex $nclozes $found]
            db eval {UPDATE cards SET fact_data=$ncloze WHERE uid=$uid}
        } else {
            db eval {DELETE FROM cards WHERE uid=$uid}
        }
    }
    set oclozes_first [lmap {uid cloze} $ocards {lindex $cloze 1}]
    foreach ncloze $nclozes {
        set found [lsearch -exact $oclozes_first [lindex $ncloze 1]]
        if {$found == -1} {
            add_card $fact_uid $ncloze
        }
    }
}

proc get_clozes {question} {
    return [regexp -inline -all {\[cloze [^\]]*\]} $question]
}

proc check_cloze_cmd {cmd} {
    if {[llength $cmd] > 3} {
        warn "More than two arguments in cloze command: \[$cmd\]"
    }
    if {[llength $cmd] < 2} {
        warn "At least one argument required in cloze command: \[$cmd\]"
    }
}

proc add_tag_for_fact {fact_uid tag} {
    set uid [db onecolumn {SELECT uid FROM tags WHERE name=$tag}]
    if {$uid eq ""} {
        db eval {INSERT INTO tags(name) VALUES($tag)}
        set uid [db last_insert_rowid]
    }
    db eval {INSERT INTO fact_tags VALUES($fact_uid, $uid)}
}

proc morji::update_tags_for_fact {fact_uid tags} {
    set otags [db eval {
        SELECT name FROM tags
        WHERE EXISTS(SELECT 1 FROM fact_tags WHERE fact_uid=$fact_uid AND tag_uid = tags.uid)
    }]
    # new tags
    foreach tag [lsort -unique $tags] {
        if {$tag eq "all"} {
            continue
        }
        if {!($tag in $otags)} {
            add_tag_for_fact $fact_uid $tag
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
    remove_orphaned_tags
}

proc morji::remove_orphaned_tags {} {
    db eval {
        DELETE FROM tags
        WHERE NOT EXISTS(SELECT 1 FROM fact_tags WHERE fact_tags.tag_uid = tags.uid)
    }
}

proc morji::delete_fact {fact_uid} {
    db eval {DELETE FROM facts WHERE uid=$fact_uid}
    remove_orphaned_tags
}

######################### getting cards and fact data ################ 

proc morji::start_of_day {} {
    variable START_TIME
    set fmt %d/%m/%Y
    return [clock add [clock scan [clock format [clock add $START_TIME -2 hours] -format $fmt] -format $fmt] 2 hours]
}

proc morji::substcmd {text} {
    return [subst -nobackslashes -novariables $text]
}

proc morji::get_cards_where_tag_clause {} {
    return {
        EXISTS(SELECT 1 FROM tags, fact_tags, facts
            WHERE cards.fact_uid = facts.uid
            AND tags.uid = fact_tags.tag_uid
            AND facts.uid = fact_tags.fact_uid
            AND tags.active = 1)
    }
}

proc morji::get_today_cards {} {
    set tomorrow [clock add [start_of_day] 1 day]
    return [db eval [substcmd {
        SELECT cards.uid FROM cards
        WHERE next_rep < $tomorrow
        AND reps > 0 AND
        [get_cards_where_tag_clause]
        ORDER BY next_rep - last_rep
    }]]
}

proc morji::get_forgotten_cards {} {
    set tomorrow [clock add [start_of_day] 1 day]
    return [db eval [substcmd {
        SELECT cards.uid FROM cards
        WHERE next_rep < $tomorrow
        AND reps = 0 AND
        [get_cards_where_tag_clause]
        ORDER BY next_rep - last_rep
        LIMIT 25
    }]]
}

proc morji::get_new_cards {} {
    return [db eval [substcmd {
        SELECT min(cards.uid) FROM cards
        WHERE cards.next_rep ISNULL AND
        [get_cards_where_tag_clause]
        GROUP BY fact_uid
        LIMIT 5
    }]]
}

proc morji::get_card_user_info {uid} {
    return [db eval {
        SELECT facts.question, facts.answer, facts.notes, facts.type, cards.fact_data
        FROM cards, facts
        WHERE cards.uid=$uid AND facts.uid = cards.fact_uid
    }]
}

proc morji::get_fact_user_info {uid} {
    return [db eval {
        SELECT facts.question, facts.answer, facts.notes, facts.type
        FROM facts
        WHERE facts.uid=$uid
    }]
}

proc morji::get_card_tags {uid} {
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

proc morji::get_active_tags {} {
    return [db eval {SELECT name FROM tags WHERE active = 1 ORDER BY name}]
}

proc morji::get_inactive_tags {} {
    return [db eval {SELECT name FROM tags WHERE active = 0 ORDER BY name}]
}

proc morji::select_tags {pattern} {
    db eval {UPDATE tags SET active = 1 WHERE name GLOB $pattern}
}

proc morji::deselect_tags {pattern} {
    db eval {UPDATE tags SET active = 0 WHERE name GLOB $pattern}
}

######################### scheduling ################ 

proc morji::schedule_card {uid grade} {
    variable START_TIME
    db eval {SELECT last_rep, next_rep, easiness, reps, fact_uid FROM cards WHERE uid=$uid} break
    if {![info exists reps]} {
        error "internal error: schedule_card: card does not exist: $uid"
    }
    # grades are the same as in anki: again, hard, good, easy
    if {(($reps == 0) && ($grade eq "again"))} {
        # card was new or forgotten already, so no change
        return "scheduled"
    }
    if {$next_rep eq "" && $grade eq "hard"} {
        # NOTE: for unseen card grade "hard" is the same as "good"
        set grade good
    }
    switch $grade {
        hard { set easiness [expr {$easiness - 0.15}] }
        easy { set easiness [expr {$easiness + 0.1}] }
    }
    if {$easiness < 1.3} {
        set easiness 1.3
    }
    if {$grade ne "again"} {
        set new_last_rep $START_TIME
        set new_next_rep $new_last_rep
        incr reps
    } else {
        set new_last_rep $last_rep
        set new_next_rep $next_rep
        set reps 0
    }
    switch $reps {
        0 { }
        1 { 
            set new_next_rep [clock add $new_next_rep 1 day]
            if {$grade eq "easy"} {
                if {$next_rep ne ""} {
                    set new_next_rep [clock add $new_next_rep 2 days]
                } else {
                    set new_next_rep [clock add $new_next_rep 5 days]
                }
            }
        }
        2 { 
            set new_next_rep [clock add $new_next_rep 6 day]
            switch $grade {
                hard { set new_next_rep [clock add $new_next_rep -2 days] }
                easy { set new_next_rep [clock add $new_next_rep 1 day] }
            }
        }
        default {
            set interval [expr {int(($new_last_rep-$last_rep)*$easiness)}]
            set new_next_rep [clock add $new_next_rep $interval seconds]
        }
    }
    if {$reps > 0} {
        if {![info exists interval]} {
            set interval [expr {$last_rep eq "" ? 0 : $new_next_rep-$new_last_rep}]
        }
        set new_next_rep [
            clock add $new_next_rep [interval_noise $interval] days
        ]
    }
    while {[db exists {
                SELECT 1 FROM cards
                WHERE fact_uid=$fact_uid AND uid!=$uid
                AND date(next_rep-7200,'unixepoch') = date($new_next_rep-7200, 'unixepoch')}]
        } {
        # avoid putting sister cards on the same day
        set new_next_rep [clock add $new_next_rep 1 day]
    }
    db eval {
        UPDATE cards
        SET last_rep=$new_last_rep, next_rep=$new_next_rep, easiness=$easiness, reps=$reps
        WHERE uid=$uid
    }
    return "scheduled"
}

proc morji::interval_noise {interval} {
    set noise 0
    set day 86400
    # use noise calculation similar to mnemosyne's
    if {$interval <= 10 * $day} {
        set noise [expr {$day * rand() * 2}]
    } elseif {$interval <= 20 * $day} {
        set noise [expr {$day * (rand() * 5 - 2)}]
    } elseif {$interval <= 60 * $day} {
        set noise [expr {$day * (rand() * 7 - 3)}]
    } else {
        set noise [expr {$interval * (-0.05 + 0.1 * rand())}]
    }
    return [expr {int($noise / $day)}]
}

######################### fact parsing ################ 

proc morji::check_field {field_contents field} {
    if {[dict get $field_contents $field] ne ""} {
        warn "double use of $field"
    }
}

proc morji::parse_card {text} {
    set fields [textutil::splitx $text {(@(?:Question|Answer|Notes|Type|Tags):)}]
    set field_contents [dict create]
    set current_field ""
    foreach f {@Question: @Answer: @Notes: @Type: @Tags:} { dict set field_contents $f "" }
    foreach field $fields {
        switch $field {
            @Question: - @Answer: - @Notes: - @Type: - @Tags: {
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

proc morji::get_key {prompt} {
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

proc morji::get_line {prompt} {
    with_color blue {
        puts -nonewline "$prompt "
        flush stdout
    }
    return [gets stdin]
}

proc morji::draw_line {} {
    # NOTE: this is suboptimal
    puts [string repeat ─ [::term::ansi::ctrl::unix::columns]]
}

proc morji::put_help {} {
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

proc morji::put_help_initial_schedule_prompt {} {
    put_header "Keys" cyan
    puts {
  a      grade card as not memorized (again)
  g      grade card memorization as good
  e      grade card memorization as easy
  C      cancel operation
  E      edit new card
  Q      quit program}
}

proc morji::put_context_independent_help {} {
    put_context_independent_keys
}

proc morji::put_context_independent_keys {} {
    put_header "Keys" cyan
    puts {
  ?      show this help
  N      new card
  t      select tags with glob pattern
  T      deselect tags with glob pattern
  s      show cards scheduled in the next week
  S      show statistics
  Q      quit program}
}

proc morji::put_header {title {color yellow}} {
    with_color $color {
        puts -nonewline "$title: "
        flush stdout
    }
}

proc morji::put_text {text} {
    set elts [textutil::splitx $text {(\[[^\]]*\])}]
    set buf {}
    foreach elt $elts {
        if {[regexp {^\[.*\]$} $elt]} {
            set cmd [string range $elt 1 end-1]
            set cmdname [lindex $cmd 0]
            set args [lrange $cmd 1 end]
            try {
                lappend buf [morji::markup::$cmdname {*}$args]
            } on error {msg} {
                lappend buf [colored red \[$msg\]]
            }
        } else {
            lappend buf $elt
        }
    }
    # XXX: length is buggy because of ansi escape sequences
    puts [textutil::adjust [join $buf ""] -length 85]
}

proc morji::config::markup {name type arg} {
    proc ::morji::markup::$name {args} [
        string cat "return \[morji::$type $arg " {[join $args]} "\]"
    ]
}

morji::config::markup em styled bold

proc morji::markup::cloze {cloze {hint {[…]}}} {
    if {$morji::markup::CLOZE == 0} {
        set ret [morji::styled bold $hint]
    } elseif {$morji::markup::CLOZE <= -42} {
        set ret "\[cloze $cloze [morji::styled bold $hint]\]"
    } else {
        set ret $cloze
    }
    incr morji::markup::CLOZE -1
    return $ret
}

foreach {n s} {lbracket \[ rbracket \]} {
    proc morji::markup::$n {} [list return $s]
}

proc morji::put_question {question answer type fact_data} {
    put_header "Question"
    switch $type {
        oneside { put_text $question }
        twoside {
            if {$fact_data eq "R"} {
                put_text $question
            } else {
                put_text $answer
            }
        }
        cloze {
            lassign $fact_data i
            set morji::markup::CLOZE $i
            put_text $question
        }
    }
}

proc morji::put_tags {type tags} {
    put_header "Tags" yellow
    set tags [lsearch -inline -all -not -exact $tags all]
    puts $tags
}

proc morji::put_answer {question answer notes type fact_data} {
    put_header "Answer"
    switch $type {
        oneside { put_text $answer }
        twoside {
            if {$fact_data eq "R"} {
                put_text $answer
            } else {
                put_text $question
            }
        }
        cloze {
            set cloze [lindex $fact_data 1]
            puts $cloze
        }
    }
    if {[regexp {\S} $notes]} {
        put_header "Notes"
        put_text $notes
    }
}

proc morji::put_card_fields {ch {question {}} {answer {}} {notes {}} {type {}} {tags {}}} {
    puts $ch "@Question: $question"
    puts $ch "@Answer: $answer"
    puts $ch "@Notes: $notes"
    puts $ch "@Type: $type"
    puts $ch "@Tags: $tags"
}

proc morji::with_tempfile {tmp tmpfile script} {
    upvar $tmp t $tmpfile tf
    set t [file tempfile tf]
    try {
        uplevel $script
    } finally {
        close $t
        file delete $tf
    }
}

proc morji::edit_new_card {} {
    with_tempfile tmp tmpfile {
        set type [db onecolumn {SELECT value FROM misc_info WHERE key='last_added_fact_type'}]
        set tags [db onecolumn {SELECT value FROM misc_info WHERE key='last_added_fact_tags'}]
        put_card_fields $tmp {} {} {} $type $tags
        flush $tmp
        seek $tmp 0
        edit_card $tmp $tmpfile
    }
}

proc morji::edit_existent_card {card_uid} {
    with_tempfile tmp tmpfile {
        lassign [get_card_user_info $card_uid] question answer notes type
        set tags [get_card_tags $card_uid]
        set tags [lsearch -inline -all -not -exact $tags all]
        put_card_fields $tmp $question $answer $notes $type $tags
        flush $tmp
        seek $tmp 0
        db eval {SELECT fact_uid FROM cards WHERE uid=$card_uid} break
        if {$fact_uid eq ""} {
            error "internal error: edit_existent_card: no fact_uid"
        }
        edit_card $tmp $tmpfile $fact_uid
    }
}

proc morji::edit_card {tmp tmpfile {fact_uid {}}} {
    set editor $::env(EDITOR)
    if {$editor eq ""} {
        set editor vim
    }
    exec $editor [file normalize $tmpfile] <@stdin >@stdout 2>@stderr
    lassign [parse_card [read $tmp]] question answer notes type tags
    if {$question eq ""} {
        warn "Question field is empty"
    }
    if {$answer eq "" && $type ne "cloze"} {
        warn "Answer field is empty"
    }
    if {$answer ne "" && $type eq "cloze"} {
        warn "Answer field not used for card of type “cloze”"
    }
    set tags [lsearch -inline -all -not -exact $tags all]
    set tags [lsort -unique $tags]
    if {$fact_uid ne ""} {
        update_fact $fact_uid $question $answer $notes $type $tags
        show_fact $fact_uid $tags
        if {![prompt_confirmation {Ok}]} {
            throw CANCEL {}
        }
    } else {
        set fact_uid [add_fact $question $answer $notes $type $tags]
        show_fact $fact_uid tags
        set ret ""
        while {$ret ne "scheduled"} {
            set ret [ask_for_initial_grade $fact_uid]
            if {$ret eq "edit"} {
                seek $tmp 0
                delete_fact $fact_uid
                tailcall edit_card $tmp $tmpfile
            } elseif {$ret eq "cancel"} {
                delete_fact $fact_uid
                throw CANCEL {}
            }
        }
        db eval {INSERT OR REPLACE INTO misc_info VALUES('last_added_fact_type', $type)}
        db eval {INSERT OR REPLACE INTO misc_info VALUES('last_added_fact_tags', $tags)}
    }
}

proc morji::show_fact {fact_uid tags} {
    lassign [get_fact_user_info $fact_uid] question answer notes type
    foreach {f t} [list $question Question $answer Answer $notes Notes $type Type $tags Tags] {
        if {$type eq "cloze" && $t eq "Answer"} {
            continue
        }
        if {$type eq "cloze" && $t eq "Question"} {
            set morji::markup::CLOZE -42
        }
        put_header "$t"
        switch $t {
            Question - Answer - Notes { put_text $f }
            default { puts $f }
        }
    }
}

proc morji::ask_for_initial_grade {fact_uid} {
    set uids [db eval {SELECT uid FROM cards WHERE fact_uid=$fact_uid}]
    set key [get_key "(initial grade) >>"]
    switch $key {
        a { return "scheduled" }
        g { 
            foreach card_uid $uids {schedule_card $card_uid good}
            return "scheduled"
        }
        e { 
            foreach card_uid $uids {schedule_card $card_uid easy}
            return "scheduled"
        }
        E { return "edit" }
        C { return "cancel" }
        ? {
            put_help_initial_schedule_prompt
            return ""
        }
        Q { quit }
    }
    with_color red {
        puts stderr "Error: invalid key: $key (type ? for help)"
    }
}

proc morji::warn {msg} {
    with_color red {
        puts stderr "Warning: $msg"
    }
}

proc morji::put_info {msg} {
    with_color cyan {
        puts stderr "Info: $msg"
    }
}

proc morji::with_color {color script} {
    send::sda_fg$color
    try { 
        uplevel $script
    } finally {
        send::sda_fgdefault
    }
}

proc morji::colored {color text} {
    return "[::term::ansi::code::ctrl::sda_fg$color]$text[::term::ansi::code::ctrl::sda_fgdefault]"
}

proc morji::styled {style text} {
    return "[::term::ansi::code::ctrl::sda_$style]$text[::term::ansi::code::ctrl::sda_no$style]"
}

proc morji::with_style {style script} {
    send::sda_$style
    try { 
        uplevel $script
    } finally {
        send::sda_no$style
    }
}

proc morji::prompt_delete_card {uid} {
    if {[prompt_confirmation {Delete card}]} {
        db eval {SELECT fact_uid FROM cards WHERE uid=$uid} break
        delete_fact $fact_uid
        return restart
    }
}

proc morji::prompt_confirmation {prompt} {
    while {1} {
        set key [get_key "$prompt? \[Y/n\] >>"]
        switch $key {
            Y { return 1 }
            n { return 0 }
            ? { 
                put_header "Keys" cyan
                puts {Type “Y” to confirm, or “n” to cancel.}
            }
            default {
                with_color red {
                    puts stderr "Error: invalid key: $key (type ? for help)"
                }
            }
        }
    }
}

proc morji::card_prompt {card_uid} {
    variables FIRST_ACTION_FOR_CARD ANSWER_ALREADY_SEEN
    lassign [get_card_user_info $card_uid] question answer notes type fact_data
    if {$FIRST_ACTION_FOR_CARD} {
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
            set ANSWER_ALREADY_SEEN 1
            return
        }
        E { edit_existent_card $card_uid; return }
        ? { put_help; return }
        D { return [prompt_delete_card $card_uid] }
        a - h - g - e {
            if {!$ANSWER_ALREADY_SEEN} {
                error "you must see the answer before grading the card"
            }
        }
    }

    set ret [handle_base_key $key]
    if {$ret ne ""} {
        return $ret
    }

    if {$ANSWER_ALREADY_SEEN} {
        switch $key {
            a { return [schedule_card $card_uid again] }
            h { return [schedule_card $card_uid hard] }
            g { return [schedule_card $card_uid good] }
            e { return [schedule_card $card_uid easy] }
        }
    }
    error "invalid key: $key (type ? for help)"
}

proc morji::no_card_prompt {} {
    set key [get_key ">>"]
    set ret [handle_base_key $key]
    if {$ret ne ""} {
        return $ret
    }

    error "invalid key: $key (type ? for help)"
}

proc morji::handle_base_key {key} {
    variable TEST
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
        + { if {$TEST} { return next_day } }
        N { edit_new_card; return restart }
        S { show_statistics; return 1 }
        s { show_cards_scheduled_next_week; return 1 }
        Q { puts ""; return quit }
        ? { put_context_independent_help; return 1 }
    }
}

proc morji::put_stats {key value} {
    put_header $key cyan
    puts $value
}

proc morji::show_cards_scheduled_next_week {} {
    set counts {}
    set after [clock add [start_of_day] 1 day]
    for {set i 0} {$i < 7} {incr i} {
        set before $after
        set after [clock add $after 1 day]
        set scheduled [db eval [substcmd {
            SELECT count(*) FROM cards
            WHERE next_rep < $after
            AND $before <= next_rep
            AND reps > 0
            AND [get_cards_where_tag_clause]
        }]]
        lappend counts $scheduled
    }
    put_stats "Cards scheduled for next days" $counts
}

proc morji::show_statistics {} {
    set unseen [db eval [substcmd {
        SELECT count(*) FROM cards WHERE next_rep ISNULL AND [get_cards_where_tag_clause]
    }]]
    put_stats "Unseen cards" $unseen
    set not_memorized [db eval [substcmd {
        SELECT count(*) FROM cards WHERE reps = 0 AND [get_cards_where_tag_clause]
    }]]
    put_stats "Cards not memorized" $not_memorized
    set memorized [db eval [substcmd {
        SELECT count(*) FROM cards WHERE reps > 0 AND [get_cards_where_tag_clause]
    }]]
    put_stats "Memorized cards" $memorized
}

######################### main loop stuff ################

proc morji::put_phase_info {phase n} {
    switch $phase {
        get_today_cards { put_info "Review $n memorized cards." }
        get_forgotten_cards { put_info "Review $n forgotten cards." }
        get_new_cards { put_info "Memorize $n new cards." }
    }
}

proc morji::put_screen_start {} {
    send::clear
    puts "Type ? for help."
}

proc morji::within_transaction {script} {
    set ret ""
    try {
        set ret [db transaction {uplevel $script}]
    } trap {CANCEL} {msg} {
        if {$msg ne ""} {
            put_info $msg
        }
    } on error {msg} {
        with_color red {
            puts stderr "Error: $msg"
        }
    } finally {
        return $ret
    }
}

proc morji::run {} {
    variables FIRST_ACTION_FOR_CARD ANSWER_ALREADY_SEEN TEST
    set found_cards 0
    foreach f {get_today_cards get_forgotten_cards get_new_cards} {
        set cards [db transaction {$f}]
        if {[llength $cards] > 0} {
            set found_cards 1
            set n [llength $cards]
        }
        foreach card $cards {
            put_screen_start
            put_phase_info $f $n
            incr n -1
            set ret ""
            set FIRST_ACTION_FOR_CARD 1
            set ANSWER_ALREADY_SEEN 0
            while {$ret ne "scheduled"} {
                set ret [within_transaction {card_prompt $card}]
                set FIRST_ACTION_FOR_CARD 0
                switch $ret {
                    quit { quit }
                    restart { tailcall run }
                    next_day { tailcall test_go_to_next_day }
                }
            }
        }
    }
    if {$found_cards} {
        tailcall run
    }
    if {$TEST} {
        tailcall test_go_to_next_day
    } else {
        put_screen_start
        put_info "No cards to review nor new cards"
        set ret ""
        while {1} {
            set ret [within_transaction {no_card_prompt}]
            switch $ret {
                quit { quit }
                restart { tailcall run }
            }
        }
    }
}

proc morji::main {} {
    set ret 0
    try {
        run
    } on error {result} {
        with_color red {
            puts stderr "Fatal Error: $result"
        }
        set ret 1
    } finally {
        db close
    }
    exit $ret
}

proc morji::quit {} {
    db close
    exit
}

proc morji::init {{dbfile :memory:}} {
    try {
        init_state $dbfile
    } on error {msg} {
        with_color red {
            puts stderr "Error initializing database: $msg"
        }
        if {[namespace which db] ne ""} {
            db close
        }
        exit 1
    }
}

proc morji::read_config {} {
    if {[info exists ::env(XDG_CONFIG_HOME)]} {
        set config_dir $::env(XDG_CONFIG_HOME)/morji
    } else {
        set config_dir ~/.config/morji
    }
    if {![file exists $config_dir] || ![file exists $config_dir/init.tcl]} {
        file mkdir $config_dir
        set fh [open $config_dir/init.tcl w]
        puts $fh {# morji configuration file
#markup word colored blue
}
        close $fh
    }
    namespace eval config source $config_dir/init.tcl
}

if {!([info exists morji::TEST] && $morji::TEST)} {
    set morji::TEST 0
    try {
        morji::read_config
    } on error {msg} {
        with_color red {
            puts stderr "Error reading configuration file: $msg"
        }
    }
    morji::init
    morji::main
}
