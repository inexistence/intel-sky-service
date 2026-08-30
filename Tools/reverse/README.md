# Reverse-engineering helpers

`swift-field-metadata.mjs` reads Swift field descriptors directly from a 64-bit little-endian
Mach-O `__swift5_fieldmd` section. It avoids loading or executing the reference runtime and does
not require its architecture to match the host.

```sh
node Tools/reverse/swift-field-metadata.mjs /path/to/SkyComputerUseService RefetchableSkyshotAXTree
```

The optional query matches both type names and field/case names. Mangled field types may contain
Swift symbolic-reference bytes; field and enum-case names remain directly readable.

`softlink-symbol-hash.mjs` reproduces the official `SoftLink` symbol-request hash. Supply the salt
embedded at the relevant call site and one or more candidate Mach-O symbol names:

```sh
node Tools/reverse/softlink-symbol-hash.mjs SALT _AXUIElementGetActualPid
node --test Tools/reverse/softlink-symbol-hash.test.mjs
```

The hash is SipHash-2-4 over UTF-8 `symbol + salt` with the fixed key recovered from the bundled
implementation. A hash match proves the requested spelling; it does not by itself prove that the
symbol exists on the running macOS release or that calling it is safe.

`asar-search.mjs` searches packed files in an Electron ASAR without extracting or changing the
installed application. The query and optional file filter are case-insensitive regular
expressions; context and result count are bounded.

```sh
node Tools/reverse/asar-search.mjs /Applications/ChatGPT.app/Contents/Resources/app.asar \
  'setServiceProcessIdentifier|onServiceAvailable' 800 '\.vite/build/main-.*\.js$' 20
node --test Tools/reverse/asar-search.test.mjs
```

Unpacked entries are listed by the parser but skipped by the search because their bytes live next
to, rather than inside, the ASAR archive.
