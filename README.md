Description
-----------

*morji* is a simple flashcard program for the terminal. It uses a modified
version of the SM2 algorithm taking inspiration from mnemosyne and anki.

Here is a list of its main features:

+ one-sided, two-sided, and cloze deletion card types
+ Use tags to organize cards by themes and choose material to review or learn
+ Use your preferred text editor to edit cards
+ Simple semantic text markup using colors
+ Simple statistics
+ Find facts to edit with a pattern
+ Importing multiple cards from text file
+ Storage in an SQLite3 database with simple schema

The program, its customization and card syntax creation are explained in the
(short) manpages morji(1), morji\_config(5) and morji\_facts(5). Man pages are
available in html form too in the [morji
website](https://bardinflor.perso.aquilenet.fr/morji/intro-en).

The *chronocram* program is a complementary flashcard Tk program for easier
initial memorization of simple cards using several spaced repetitions on the
same session.

Install
-------

You just need [Tcl](https://www.tcl.tk/) (version 8.6.\*), tcllib, and sqlite3
bindings for Tcl (often already included).

Then issue the command:

    make install PREFIX=/usr/local/

You can change `/usr/local` to any other location: just ensure that
`$PREFIX/bin` is on your `$PATH`.

The `morji` command should now be available.
