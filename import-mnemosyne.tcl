namespace eval morji {
    variable TEST 1
    namespace eval test {}
}
source -encoding utf-8 morji.tcl

sqlite3 mnemodb ~/basura/default.db -readonly true
morji::init_state

proc schema {} {
    foreach table [mnemodb eval {SELECT sql FROM sqlite_master WHERE type='table' ORDER BY name}] {
        puts $table
    }
}

proc print_table {table} {
    mnemodb eval [string cat {SELECT * FROM } $table { LIMIT 10}] values {
        parray values 
    }
}

#print_table data_for_fact
#print_table cards
proc do_twoside {tag_pattern} {
    set ids [mnemodb eval {SELECT DISTINCT _fact_id FROM cards WHERE tags GLOB $tag_pattern}]
    if {[lsort -integer -unique $ids] != $ids} {
        error "do_twoside: $tag_pattern"
    }
    puts "found [llength $ids] for pattern '$tag_pattern'"
    foreach fact_id $ids {
        set rows [mnemodb eval {SELECT 1 FROM cards WHERE _fact_id = $fact_id}]
        if {[llength $rows] != 2} {
            error "bad number of cards for $fact_id"
        }
        mnemodb eval {
            SELECT question, answer, tags, next_rep, last_rep, ret_reps_since_lapse, easiness
            FROM cards WHERE _fact_id = $fact_id
        } break
        lassign [split $answer "\n"] answer notes
        if {[regexp {rafsi} $answer]} {
            puts stderr "$question@@@$notes@@@$answer"
            puts $fact_id
        }
        set question [clean_text $question $tag_pattern]
        set answer [clean_text $answer $tag_pattern]
        set notes [clean_text $notes $tag_pattern]
        db eval {INSERT INTO facts(question, answer, notes, type) VALUES($question, $answer, $notes, 'twoside')}
        set new_fact_uid [db last_insert_rowid]
        if {$last_rep == -1} {
            unset next_rep
            unset last_rep
            if {$ret_reps_since_lapse > 0} {
                error "bad reps: $ret_reps_since_lapse"
            }
        }
        foreach data {R P} {
            db eval {
                INSERT INTO cards(last_rep, next_rep, easiness, reps, fact_uid, fact_data)
                VALUES($last_rep, $next_rep, $easiness, $ret_reps_since_lapse, $new_fact_uid, $data)
            }
        }
        switch $tag_pattern {
            *toki* { add_tag_for_fact $new_fact_uid tokipona }
            *lidep* { add_tag_for_fact $new_fact_uid lidepla }
            *gismu* { add_tag_for_fact $new_fact_uid gismu }
            *personaje* { add_tag_for_fact $new_fact_uid PAO }
        }
    }
}

proc do_oneside {tag_pattern} {
    set ids [mnemodb eval {SELECT _fact_id FROM cards WHERE tags GLOB $tag_pattern}]
    if {[lsort -integer -unique $ids] != $ids} {
        error "do_oneside: not unique: $tag_pattern"
    }
    puts "found [llength $ids] for pattern '$tag_pattern'"
    foreach fact_id $ids {
        set rows [mnemodb eval {SELECT 1 FROM cards WHERE _fact_id = $fact_id}]
        if {[llength $rows] != 1} {
            error "bad number of cards for $fact_id"
        }
        mnemodb eval {
            SELECT question, answer, tags, next_rep, last_rep, ret_reps_since_lapse, easiness
            FROM cards WHERE _fact_id = $fact_id
        } break
        set question [clean_text $question $tag_pattern]
        set answer [clean_text $answer $tag_pattern]
        db eval {INSERT INTO facts(question, answer, notes, type) VALUES($question, $answer, '', 'oneside')}
        set new_fact_uid [db last_insert_rowid]
        if {$last_rep == -1} {
            unset next_rep
            unset last_rep
            if {$ret_reps_since_lapse > 0} {
                error "bad reps: $ret_reps_since_lapse"
            }
        }
        db eval {
            INSERT INTO cards(last_rep, next_rep, easiness, reps, fact_uid, fact_data)
            VALUES($last_rep, $next_rep, $easiness, $ret_reps_since_lapse, $new_fact_uid, '')
        }
        switch $tag_pattern {
            lojban { add_tag_for_fact $new_fact_uid lojban-sentence }
            lojban-cll { add_tag_for_fact $new_fact_uid lojban-cll }
            *vorto* { add_tag_for_fact $new_fact_uid vorto }
            *Mc* { add_tag_for_fact $new_fact_uid idioms }
            *euskara* { add_tag_for_fact $new_fact_uid euskara }
        }
    }
}

morji::define_markup sep colored magenta
morji::define_markup link colored blue
morji::define_markup example styled italic
morji::define_markup var styled italic
morji::define_markup rafsi styled italic
morji::define_markup paren colored cyan
morji::define_markup type colored cyan

proc clean_text {text pattern} {
    regsub -all {\[} $text {(} text
    regsub -all {\]} $text {)} text

    regsub -all {<i><font} $text {<font} text
    regsub -all {<b><font} $text {<font} text

    if {$pattern eq "*Mc*"} {
        regsub -all {<a href="[^"]*">(.*?)</a>} $text {[link \1]} text
        regsub -all {<a href="[^"]*">(.*?)</a>} $text {[link \1]} text
        regsub -all {<font color="purple">} $text {[em } text
        regsub -all {<font color="maroon">} $text {[sep } text
        regsub -all {<font color="#000066">} $text {[example } text
    }

    if {$pattern eq "*gismu*"} {
        regsub -all {<font color="#859900">/</font>} $text {/} text
        regsub -all {<font color="#2aa198"><i>} $text {[var } text
        regsub -all {<font color="#6c71c4">} $text {[paren } text
        regsub -all {\(<font color="#d33682">} $text {(} text
        regsub -all {</font>\)} $text {)} text
        regsub -all {<font color="#?268bd2">} $text {[type } text
        regsub -all {<font color="#?93a1a1"><b>} $text {[var } text
        regsub -all {<i>} $text {[rafsi } text
        regsub -all {<b>} $text {[em } text
    }

    regsub -all {<b>} $text {[em } text
    regsub -all {<i>} $text {[em } text

    regsub -all {</font></i>} $text "\]" text
    regsub -all {</font></b>} $text "\]" text
    regsub -all {</i></font>} $text "\]" text
    regsub -all {</b></font>} $text "\]" text
    regsub -all {</(?:font|b|i)>} $text "\]" text
    regsub -all {<br>} $text "\n" text
    regsub -all " \\\]" $text "\] " text

    if {[regexp {<\w+>} $text]} {
        puts stderr $text
    }
    if {[regexp {</\w+>} $text]} {
        puts stderr $text
    }

    return $text
}

proc escape_text {text} {
    regsub -all {\[} $text {<<} text
    regsub -all {\]} $text {>>} text
    return $text
}

#foreach tag {tokipona lidepla gismu lojban-sentence lojban-cloze vorto idioms euskara esapideak PAO} {
#    db eval {
#        INSERT INTO tags(name) VALUES($tag)
#    }
#}

db transaction {
    do_twoside {*toki*}
    do_twoside {*lidepla*}
    do_twoside {*gismu*}
    do_twoside {*personaje*}

    do_oneside {*euskara*}
    do_oneside {lojban}
    do_oneside {lojban-cll}
    #do_oneside {*vortoj}
    do_oneside {*Mc*}
}
set morji::TEST 0
morji::main
