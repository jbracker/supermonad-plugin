
DIR:=$(shell pwd)

install: init
	cabal install

clean: init
	cabal clean
	rm -fR ./examples/monad/session/dist
	rm -fR ./examples/monad/effect/dist
	rm -fR ./examples/monad/constrained/dist
	
	rm -fR ./examples/monad/session-chat/original/dist
	rm -fR ./examples/monad/session-chat/supermonad/dist
	
	rm -fR ./examples/monad/hmtc/original/dist
	rm -fR ./examples/monad/hmtc/supermonad/dist
	rm -fR ./examples/monad/hmtc/monad-param/dist
	
	rm -fR ./examples/arrow/ebba/dist
	cabal sandbox delete-source $(DIR)/examples/arrow/ebba/gnewplot
	rm -fR ./examples/arrow/ebba/gnewplot
	rm -f  ./examples/arrow/ebba/*.eps
	
	rm -fR ./examples/arrow/reversible-indexed/dist
	
	rm -fR ./dist
	rm -f  ./*.eps

clean-sandbox:
	rm -fR ./.cabal-sandbox
	rm -f ./cabal.sandbox.config

doc: init
	cabal configure && cabal haddock --internal --executables

opendoc:
	xdg-open ./dist/doc/html/supermonad-plugin/index.html 

init:
	[ -f ./cabal.sandbox.config ] || [ -d ./.cabal-sandbox ] || cabal sandbox init

supermonad-examples: install minimal-example session-example session-chat-supermonad-example effect-example constrained-example hmtc-supermonad-example

superarrow-examples: install ebba-example reversible-indexed-example

minimal-example: install
	cabal install ./examples/monad/minimal

session-example: install
	cabal install ./examples/monad/session

session-chat-orig-example: init
	cabal install ./examples/monad/session-chat/original

session-chat-supermonad-example: init
	cabal install ./examples/monad/session-chat/supermonad

effect-example: install
	cabal install ./examples/monad/effect

constrained-example: install
	cabal install ./examples/monad/constrained

hmtc-orig-example: init
	cabal install ./examples/monad/hmtc/original

hmtc-supermonad-example: install
	cabal install ./examples/monad/hmtc/supermonad
	
hmtc-monad-param-example: init
	cabal install ./examples/monad/hmtc/monad-param

ebba-example: install
	[ -d ./examples/arrow/ebba/gnewplot ] || ( \
		git clone https://github.com/glutamate/gnewplot.git ./examples/arrow/ebba/gnewplot && \
		cabal sandbox add-source ./examples/arrow/ebba/gnewplot )
	cabal install ./examples/arrow/ebba

reversible-indexed-example: init
	cabal install ./examples/arrow/reversible-indexed


