#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# This script checks that a Menhir tarball can be compiled and installed.
# The command line argument should be the tarball's name without .tar.gz.

PACKAGE="$1"
TARBALL=$PACKAGE.tar.gz

# Some of the demos assume Menhir has been installed using ocamlfind, so that
# is what we do. For this reason, we must first check that ocamlfind does not
# already have some version of menhirLib and menhirSdk.

# We use a dedicated opam switch where it is permitted to uninstall/reinstall
# Menhir.

echo "Now switching to test-menhir..."
eval $(opam env --set-switch --switch test-menhir)
OPAMYES=true opam install ocamlfind ocamlbuild coq dune

# Uninstall Menhir if it is installed.

if ocamlfind query menhirLib >/dev/null 2>/dev/null ; then
  if opam list -i menhir 2>/dev/null | grep -v -e "^#" | grep menhir ; then
    echo "Warning: menhir is already installed. Removing it..." ;
#   read -p "Can I remove it [Enter/^C]?" -n 1 -r ;
    opam remove menhir ;
  else
    echo "Warning: menhirLib is already installed. Removing it..." ;
#   read -p "Can I remove it [Enter/^C]?" -n 1 -r ;
    ocamlfind remove menhirLib ;
    ocamlfind remove menhirSdk || true ;
  fi ;
fi

# Create a temporary directory; extract, build, and install the package into
# it; build the demos using the installed binary.

TEMPDIR=`mktemp -d /tmp/menhir-test.XXXXXX`
INSTALL=$TEMPDIR/install
COQCONTRIB=$INSTALL/coq-contrib

cp $TARBALL $TEMPDIR

echo "   * Extracting. "
(cd $TEMPDIR && tar xfz $TARBALL)

echo "   * Compiling and installing."
mkdir $INSTALL
(cd $TEMPDIR/$PACKAGE &&
  make PREFIX=$INSTALL USE_OCAMLFIND=true &&
  make PREFIX=$INSTALL USE_OCAMLFIND=true install &&
  make -C coq-menhirlib all &&
  make -C coq-menhirlib CONTRIB=$COQCONTRIB install
) > $TEMPDIR/install.log 2>&1 || (cat $TEMPDIR/install.log; exit 1)

echo "   * Building the demos."
(cd $TEMPDIR/$PACKAGE &&
  make MENHIR=$INSTALL/bin/menhir COQINCLUDES="-R $COQCONTRIB/MenhirLib MenhirLib" -C demos
) > $TEMPDIR/demos.log 2>&1 || (cat $TEMPDIR/demos.log; exit 1)

echo "   * Uninstalling."
(cd $TEMPDIR/$PACKAGE &&
  make PREFIX=$INSTALL USE_OCAMLFIND=true uninstall
  make -C coq-menhirlib CONTRIB=$COQCONTRIB uninstall
) > $TEMPDIR/uninstall.log 2>&1 || (cat $TEMPDIR/uninstall.log; exit 1)

rm -rf $TEMPDIR
