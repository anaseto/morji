.PHONY: install test tags

install:
	mkdir -p ${PREFIX}/bin
	cp morji.tcl ${PREFIX}/bin/morji
	chmod u+x ${PREFIX}/bin/morji
	mkdir -p ${PREFIX}/share/man/man1
	cp morji.1 ${PREFIX}/share/man/man1/
	mkdir -p ${PREFIX}/share/man/man5
	cp morji_config.5 ${PREFIX}/share/man/man5/
	cp morji_facts.5 ${PREFIX}/share/man/man5/

test:
	tclsh8.6 morji.test
	tclsh8.6 test_expect.tcl

tags:
	ectags morji.tcl
