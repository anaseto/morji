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

proc print {table} {
    mnemodb eval [string cat {SELECT * FROM } $table { LIMIT 10}] values {
        parray values 
    }
}

#print data_for_fact
#print cards
set facts [dict create]
set ret [mnemodb eval {
    SELECT _fact_id, question, answer, tags, next_rep, last_rep, ret_reps_since_lapse, easiness
        FROM cards WHERE tags GLOB '*toki*' LIMIT 10}]
foreach {_fact_id question answer tags next_rep last_rep ret_reps_since_lapse easiness} $ret {
    puts $tags
}
set ret [mnemodb eval {SELECT distinct _fact_id FROM cards }]
if {[lsort -integer -unique $ret] != $ret} {
    puts "error"
}
