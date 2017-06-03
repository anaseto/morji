.PHONY: install test tags

install:
	cp morji.tcl ${PREFIX}/bin/morji
	cp morji.1 ${PREFIX}/share/man/man1/
	cp morji_syntax.5 ${PREFIX}/share/man/man5/

test:
	tclsh8.6 morji.test
	tclsh8.6 test_expect.tcl

tags:
	ectags morji.tcl
