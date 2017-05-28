namespace eval morji {
    variable TEST 1
    namespace eval test {}
}
source -encoding utf-8 morji.tcl

sqlite3 mnemodb ~/basura/default.db -readonly true
morji::process_config
morji::init

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

proc add_tag_all {fact_uid} {
    set all_uid [db onecolumn {SELECT uid FROM tags WHERE name='all'}]
    db eval {INSERT INTO fact_tags(fact_uid, tag_uid) VALUES($fact_uid, $all_uid)}
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

db eval {INSERT INTO tags(name) VALUES('all')}

#morji::config::markup sep colored magenta
#morji::config::markup link colored blue
#morji::config::markup example styled italic
#morji::config::markup var styled italic
#morji::config::markup rafsi styled italic
#morji::config::markup paren colored cyan
#morji::config::markup type colored cyan

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

    #if {[regexp {<\w+>} $text]} {
    #    puts stderr $text
    #}
    #if {[regexp {</\w+>} $text]} {
    #    puts stderr $text
    #}

    return $text
}

proc escape_text {text} {
    regsub -all {\[} $text {<<} text
    regsub -all {\]} $text {>>} text
    return $text
}

proc morji::check_database {} {
    puts -nonewline "checking database… "
    if {![check_all_tag]} {
        puts stderr "tag 'all' not found for all cards"
        return 0
    }
    if {![check_oneside]} {
        puts stderr "check oneside"
        return 0
    }
    if {![check_twoside]} {
        puts stderr "check twoside"
        return 0
    }
    puts "ok"
    return 1
}

proc morji::check_all_tag {} {
    set all_uid [db onecolumn {SELECT uid FROM tags WHERE name='all'}]
    set uids [db eval {
        SELECT 1 FROM facts
        WHERE NOT EXISTS (SELECT 1 FROM fact_tags WHERE fact_uid = facts.uid AND fact_tags.tag_uid=$all_uid)
    }]
    if {$uids ne ""} {
        return 0
    }
    return 1
}

proc morji::check_oneside {} {
    db eval {SELECT uid FROM facts WHERE type = 'oneside'} {
        set count [db eval {SELECT count(*) FROM cards WHERE fact_uid=$uid}]
        if {$count != 1} {
            return 0
        }
    }
    return 1
}

proc morji::check_twoside {} {
    db eval {SELECT uid FROM facts WHERE type = 'twoside'} {
        set count [db eval {SELECT count(*) FROM cards WHERE fact_uid=$uid}]
        if {$count != 2} {
            return 0
        }
        set data R
        db eval {SELECT fact_data FROM cards WHERE fact_uid=$uid} {
            if {$data ne $fact_data} {
                return 0
            }
            set data P
        }
    }
    return 1
}

set Patterns [dict create]
proc tag_pattern {pattern type tag} {
    global Patterns
    dict set Patterns $pattern type $type
    dict set Patterns $pattern tag $tag
}

proc add_tag_for_pattern {fact_uid pattern} {
    global Patterns
    add_tag_for_fact $fact_uid [dict get $Patterns $pattern tag]
}

tag_pattern *tokipona* twoside tokipona
tag_pattern *lidepla* twoside lidepla
tag_pattern *gismu* twoside gismu
tag_pattern *personaje* twoside PAO

tag_pattern *euskara* oneside esapideak
tag_pattern lojban oneside lojban-sentence
tag_pattern *lojban-cll* oneside lojban-cll
tag_pattern vortoj oneside vortoj
#tag_pattern *Mc* oneside idioms

proc gen_db {} {
    global Patterns
    db transaction {
        dict for {pattern data} $Patterns {
            do_[dict get $data type] $pattern
        }
    }
}
gen_db
if {![morji::check_database]} {
    puts stderr "invalid database"
}
set morji::TEST 0
morji::main
