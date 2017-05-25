#!/usr/bin/env tclsh8.6

set fh [open [lindex $argv 0] w]
puts $fh {
@Question: question
@Answer: answer
@Notes: notes
@Type: oneside
@Tags: mytag
}
close $fh
