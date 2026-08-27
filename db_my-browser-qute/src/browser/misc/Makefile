PYTHON = python3
PREFIX ?= /usr/local
ICONSIZES = 16 24 32 48 64 128 256 512
DATAROOTDIR = $(PREFIX)/share
DATADIR ?= $(DATAROOTDIR)
MANDIR ?= $(DATAROOTDIR)/man
A2X ?= a2x

ifdef DESTDIR
SETUPTOOLSOPTS = --root="$(DESTDIR)"
endif

all: man
	$(PYTHON) setup.py build

man: doc/my-browser-qute.1
doc/my-browser-qute.1: doc/my-browser-qute.1.asciidoc
	$(A2X) -f manpage $<

install: man
	$(PYTHON) setup.py install --prefix="$(PREFIX)" --optimize=1 $(SETUPTOOLSOPTS)
	install -Dm644 misc/org.mybrowser.qute.appdata.xml \
		"$(DESTDIR)$(DATADIR)/metainfo/org.mybrowser.qute.appdata.xml"
	install -Dm644 doc/my-browser-qute.1 \
		"$(DESTDIR)$(MANDIR)/man1/my-browser-qute.1"
	install -Dm644 misc/org.mybrowser.qute.desktop \
		"$(DESTDIR)$(DATADIR)/applications/org.mybrowser.qute.desktop"
	$(foreach i,$(ICONSIZES),install -Dm644 "qutebrowser/icons/qutebrowser-$(i)x$(i).png" \
			"$(DESTDIR)$(DATADIR)/icons/hicolor/$(i)x$(i)/apps/my-browser-qute.png";)
	install -Dm644 qutebrowser/icons/qutebrowser.svg \
		"$(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/my-browser-qute.svg"
	install -Dm755 -t "$(DESTDIR)$(DATADIR)/my-browser-qute/userscripts/" \
		$(filter-out misc/userscripts/__pycache__,$(wildcard misc/userscripts/*))
	install -Dm755 -t "$(DESTDIR)$(DATADIR)/my-browser-qute/scripts/" \
		$(filter-out scripts/__init__.py scripts/__pycache__ scripts/dev \
		  scripts/testbrowser scripts/asciidoc2html.py scripts/setupcommon.py \
			scripts/link_pyqt.py,$(wildcard scripts/*))

.PHONY: all man install
