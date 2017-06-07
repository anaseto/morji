# This script was used to import a specific set of cards from a mnemosyne
# database. It is not generic, but could probably be easily be adapted to
# import other set of cards.
#
# Use it with the -x option of morji.

proc add_tag_all {fact_uid} {
    set all_uid [db onecolumn {SELECT uid FROM tags WHERE name='all'}]
    db eval {INSERT INTO fact_tags(fact_uid, tag_uid) VALUES($fact_uid, $all_uid)}
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
            SELECT question, answer, tags, next_rep, last_rep, ret_reps_since_lapse, easiness, acq_reps_since_lapse
            FROM cards WHERE _fact_id = $fact_id
        } break
        set question [clean_text $question $tag_pattern]
        set answer [clean_text $answer $tag_pattern]
        db eval {INSERT INTO facts(question, answer, notes, type) VALUES($question, $answer, '', 'oneside')}
        set new_fact_uid [db last_insert_rowid]
        add_tag_all $new_fact_uid
        if {$last_rep == -1} {
            unset next_rep
            unset last_rep
            if {$ret_reps_since_lapse > 0} {
                error "bad reps: $ret_reps_since_lapse"
            }
        } elseif {$last_rep >= 0 && ($ret_reps_since_lapse > 0 || $acq_reps_since_lapse > 0)} {
            incr ret_reps_since_lapse
            incr next_rep 86400
            incr last_rep 86400
        }
        db eval {
            INSERT INTO cards(last_rep, next_rep, easiness, reps, fact_uid, fact_data)
            VALUES($last_rep, $next_rep, $easiness, $ret_reps_since_lapse, $new_fact_uid, '')
        }
        add_tag_for_pattern $new_fact_uid $tag_pattern
    }
}

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
            SELECT question, answer, tags, next_rep, last_rep, ret_reps_since_lapse, easiness, acq_reps_since_lapse
            FROM cards WHERE _fact_id = $fact_id
        } break
        lassign [split $answer "\n"] answer notes
        if {[regexp {rafsi} $answer]} {
            error "$question@@@$notes@@@$answer"
        }
        set question [clean_text $question $tag_pattern]
        set answer [clean_text $answer $tag_pattern]
        set notes [clean_text $notes $tag_pattern]
        db eval {INSERT INTO facts(question, answer, notes, type) VALUES($question, $answer, $notes, 'twoside')}
        set new_fact_uid [db last_insert_rowid]
        add_tag_all $new_fact_uid
        set data R
        mnemodb eval {
            SELECT next_rep, last_rep, ret_reps_since_lapse, easiness
            FROM cards WHERE _fact_id = $fact_id
        } {
            if {$last_rep == -1} {
                unset next_rep
                unset last_rep
                if {$ret_reps_since_lapse > 0} {
                    error "bad reps: $ret_reps_since_lapse"
                }
            } elseif {$last_rep >= 0 && ($ret_reps_since_lapse > 0 || $acq_reps_since_lapse > 0)} {
                incr ret_reps_since_lapse
                incr next_rep 86400
                incr last_rep 86400
            }
            db eval {
                INSERT INTO cards(last_rep, next_rep, easiness, reps, fact_uid, fact_data)
                VALUES($last_rep, $next_rep, $easiness, $ret_reps_since_lapse, $new_fact_uid, $data)
            }
            set data P
        }
        add_tag_for_pattern $new_fact_uid $tag_pattern
    }
}

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
    regsub -all "\\\[(\\w+)  " $text { [\1 } text
    regsub -all {"([^"]*)"} $text {“\1”} text
    regsub -all {\[em ϟ\]} $text {} text

    #if {[regexp {<\w+>} $text]} {
    #    puts stderr $text
    #}
    #if {[regexp {</\w+>} $text]} {
    #    puts stderr $text
    #}

    return $text
}

proc add_tag_for_pattern {fact_uid pattern} {
    global Patterns
    add_tag_for_fact $fact_uid [dict get $Patterns $pattern tag]
}

proc tag_pattern {pattern type tag} {
    global Patterns
    dict set Patterns $pattern type $type
    dict set Patterns $pattern tag $tag
}

proc import_cards {} {
    global Patterns
    db transaction {
        dict for {pattern data} $Patterns {
            do_[dict get $data type] $pattern
        }
    }
}

# required in config file:
#
#   markup sep colored magenta
#   markup link colored blue
#   markup example styled italic
#   markup var styled italic
#   markup rafsi styled italic
#   markup paren colored cyan
#   markup type colored cyan

set Patterns [dict create]
tag_pattern *Mc* oneside idioms
tag_pattern *euskara* oneside esapideak
tag_pattern lojban oneside lojban-sentence
tag_pattern *lojban-cll* oneside lojban-cll
tag_pattern vortoj oneside vortoj

tag_pattern *tokipona* twoside tokipona
tag_pattern *lidepla* twoside lidepla
tag_pattern *gismu* twoside gismu
tag_pattern *personaje* twoside PAO

sqlite3 mnemodb ~/.local/share/mnemosyne/default.db -readonly true
db eval {INSERT OR IGNORE INTO tags(name) VALUES('all')}
import_cards
