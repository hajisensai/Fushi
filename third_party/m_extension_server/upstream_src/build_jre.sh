#!/bin/bash

set -e

JRE_DIR="jre"
rm -rf "$JRE_DIR"
jlink --add-modules java.base,java.compiler,java.datatransfer,java.desktop,java.instrument,java.logging,java.management,java.naming,java.prefs,java.scripting,java.se,java.security.jgss,java.security.sasl,java.sql,java.transaction.xa,java.xml,jdk.attach,jdk.crypto.ec,jdk.jdi,jdk.management,jdk.net,jdk.unsupported,jdk.unsupported.desktop,jdk.zipfs,jdk.accessibility --output "$JRE_DIR" --strip-debug --no-man-pages --no-header-files --compress=2
