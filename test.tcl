proc test_go_to_next_day {} {
    variable START_TIME
    draw_line
    show_info "... Next Day (testing)"
    draw_line
    puts -nonewline "from [clock format $START_TIME] "
    set START_TIME [clock add $START_TIME 1 day]
    puts "to [clock format $START_TIME]"
    set key [get_key "(press any key or Q to quit) >>"]
    if {$key eq "Q"} {
        quit
    }
    tailcall run
}

proc test {} {
    init_globals
    set i 0
    db transaction {
        while {$i<2} {
            add_fact question$i answer$i notes simple english
            incr i
        }
    }
    set i 0
    db transaction {
        while {$i < 2} {
            add_fact question$i answer$i notes voc lojban
            incr i
        }
    }
    set i 1
    #db transaction {
        #while {$i < 5000} {
            #schedule_card $i 4
            #incr i
        #}
    #}
    #puts [check_database]
    #dump_database
    main
}

proc dump_database {} {
    puts [db eval {SELECT * FROM facts} cards { parray cards }]
    puts [db eval {SELECT * FROM facts} facts { parray facts }]
    puts [db eval {SELECT * FROM tags} tags { parray tags }]
    puts [db eval {SELECT * FROM fact_tags} fact_tags { parray fact_tags }]
}

proc check_database {} {
    set ret [db eval {
        SELECT uid FROM facts
        WHERE NOT EXISTS(
            SELECT 1 FROM fact_tags, tags
            WHERE facts.uid = fact_tags.fact_uid
            AND fact_tags.tag_uid = tags.uid
            AND tags.name = 'all')
    }]
    return [string equal $ret ""]
}

set TEST 1
source -encoding utf-8 morji.tcl
test
