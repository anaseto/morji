namespace eval morji {
    variable TEST 1
    namespace eval test {}
}
source -encoding utf-8 morji.tcl

proc morji::test_go_to_next_day {} {
    variable START_TIME
    draw_line
    put_info "... Next Day (testing)"
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

proc morji::interactive_test {} {
    variable START_TIME
    process_config
    init
    db transaction {
        for {set i 0} {$i < 1} {incr i} {
            add_fact "What is the answer n°\[em $i\]?" "This is the answer n°\[em $i\]" notes oneside english
            incr i
        }
    }
    db transaction {
        for {set i 0} {$i < 1} {incr i} {
            add_fact "hitz \[em $i\]" "valsi \[em $i\]" notes twoside lojban
            incr i
        }
    }
    start
}

proc morji::big_test {} {
    variable START_TIME
    init
    db transaction {
        for {set i 0} {$i < 7000} {incr i} {
            add_fact "What is the answer n°\[em $i\]?" "This is the answer n°\[em $i\]" notes oneside english
        }
    }
    db transaction {
        for {set i 0} {$i < 7000} {incr i} {
            add_fact "hitz \[em $i\]" "vorto \[em $i\]" notes twoside lojban
        }
    }
    db transaction {
        set j 0
        set interval 0
        for {set j 0} {$j < 500} {incr j} {
            set cards [get_today_cards]
            foreach uid $cards {
                schedule_card $uid good
            }
            for {set i [expr {$j * 15 + 1}]} {$i < 7000*3 && $i <= ($j+1) * 15} {incr i} {
                schedule_card $i good
                incr k
            }
            set START_TIME [clock add $START_TIME 1 day]
        }
    }
    #puts [check_database]
    #dump_database
    start
}

proc morji::dump_database {} {
    puts [db eval {SELECT * FROM facts} cards { parray cards }]
    puts [db eval {SELECT * FROM facts} facts { parray facts }]
    puts [db eval {SELECT * FROM tags} tags { parray tags }]
    puts [db eval {SELECT * FROM fact_tags} fact_tags { parray fact_tags }]
}

proc morji::check_database {} {
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

#morji::interactive_test
morji::big_test
