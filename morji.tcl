package require sqlite3

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
		active INTEGER NOT NULL
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
		front TEXT NOT NULL,
		back TEXT NOT NULL,
		extra_data TEXT NOT NULL,
		-- simple/vocabulary(recognition/production)/cloze...
		type TEXT NOT NULL
	)
}

set START_TIME [clock seconds]

proc add_fact {front back extra_data type {tags {}}} {
	db eval {INSERT INTO facts(front, back, extra_data, type) VALUES($front, $back, $extra_data, $type)}
	set fact_uid [db last_insert_rowid]
	switch $type {
		"simple" {
			db eval {INSERT INTO cards(easyness, reps, fact_uid, fact_data) VALUES(2.5, 0, $fact_uid, "")}
		}
		"voc" {
			foreach fact_data {R P} {
				db eval {INSERT INTO cards(easyness, reps, fact_uid, fact_data) VALUES(2.5, 0, $fact_uid, $fact_data)}
			}
		}
		default {
			error "invalid type: $type"
		}
	}
	set tag_uids {}
	lappend tags _all
	foreach tag $tags {
		lappend tag_uids [db eval {SELECT uid FROM tags WHERE name=$tag}]
	}
	foreach uid [lsort -unique $tag_uids] {
		db eval {INSERT INTO fact_tags VALUES($fact_uid, $uid)}
	}
}

proc update_fact {fact_uid front back extra_data type {tags {}}} {
	set otype [db eval {SELECT type FROM facts WHERE uid=$fact_uid}]
	db eval {UPDATE facts SET front=$front, back=$back, extra_data=$extra_data WHERE uid=$fact_uid}
	if {[string equal $type simple] && [string equal $otype voc] } {
		db eval {UPDATE cards SET fact_data = 'R' WHERE fact_uid = $fact_uid}
		db eval {INSERT INTO cards(easyness, reps, fact_uid, fact_data) VALUES(2.5, 0, $fact_uid, 'P')}
	} elseif {[string equal $type voc] && [string equal $otype simple] } {
		db eval {DELETE FROM cards WHERE fact_uid=$fact_uid AND fact_data = 'P'}
		db eval {UPDATE cards SET fact_data = '' WHERE fact_uid=$fact_uid}
	}
}

proc create_tag {tag} {
	db eval {INSERT INTO tags(name, active) VALUES($tag, 1)}
}

proc activate_tag {tag {active 1}} {
	db eval {UPDATE tags SET active=$active WHERE tag=$tag}
}

proc start_of_day {} {
	global START_TIME
	set fmt %d/%m/%y
	return [clock add [clock scan [clock format $START_TIME -format $fmt] -format $fmt] 2 hours]
}

proc get_today_cards {} {
	set tomorrow [clock add [start_of_day] 1 day]
	return [db eval {
		SELECT cards.uid FROM cards, tags, fact_tags, facts
		WHERE next_rep < $tomorrow
		AND cards.fact_uid = facts.uid
		AND facts.uid = fact_tags.fact_uid
		AND (EXISTS(SELECT 1 FROM tags WHERE tags.name = '_all' AND tags.active = 1)
			OR EXISTS(SELECT 1 WHERE tags.uid = fact_tags.tag_uid AND tags.active = 1))
		ORDER BY next_rep - last_rep
	}]
}

proc get_new_cards {} {
	return [db eval {
		SELECT cards.uid FROM cards, tags, fact_tags, facts
		WHERE cards.next_rep ISNULL
		AND cards.fact_uid = facts.uid
		AND facts.uid = fact_tags.fact_uid
		AND (EXISTS(SELECT 1 FROM tags WHERE tags.name = '_all' AND tags.active = 1)
			OR EXISTS(SELECT 1 WHERE tags.uid = fact_tags.tag_uid AND tags.active = 1))
	}]
}

proc get_card_user_info {uid} {
	return [db eval {SELECT facts.front, facts.back FROM cards, facts WHERE cards.uid=$uid AND facts.uid = cards.fact_uid} break]
}

proc delete_fact {uid} {
	db eval {DELETE FROM facts WHERE uid=$uid}
}

proc delete_tag {tag} {
	db eval {DELETE FROM tags WHERE name=$tag}
}

proc schedule_card {uid grade} {
	global START_TIME
	db eval {SELECT last_rep, next_rep, easyness, reps FROM cards WHERE uid=$uid} {
		set easyness [expr {$easyness + (0.1 - (5.0-$grade)*(0.08 + (5.0-$grade)*0.02))}]
		set new_last_rep $START_TIME
		set new_next_rep $new_last_rep
		incr reps
		# TODO: add some randomness and late revision tweaks
		switch $reps {
			1 { set new_next_rep [clock add $new_next_rep 1 day] }
			2 { set new_next_rep [clock add $new_next_rep 6 day] }
			default {
				set new_next_rep [clock add $new_next_rep [expr {($new_last_rep-$last_rep)*$easyness}] seconds]
			}
		}
		db eval {UPDATE cards SET last_rep=$new_last_rep, next_rep=$new_next_rep, easyness=$easyness , reps=$reps WHERE uid=$uid}
		break
	}
}

proc main {} {
	set card_uids [get_today_cards]
	set i 0
	foreach card $card_uids {
		incr i
		foreach f [get_card_user_info $card] {
		}
	}
	set card_uids [get_new_cards]
	foreach card $card_uids {
		incr i
		foreach f [get_card_user_info $card] {
		}
	}
	puts $i
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
	main
	#db eval {SELECT * FROM tags} tags {
		#parray tags
		#puts ""
	#}
	#db eval {SELECT * FROM facts} facts {
		#parray facts
		#puts ""
	#}

}
test

db close
