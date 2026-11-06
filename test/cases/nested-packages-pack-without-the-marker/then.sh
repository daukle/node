tar -xzOf build/daukle/node/package.tgz package/lib/compat/package.json > packed.json &&
  grep -q '"main": "../index.js"' packed.json &&
  grep -q '"name": "demo-compat"' packed.json &&
  if grep -q '"//"' packed.json; then echo "the packed nested package.json carries daukle's marker"; exit 1; fi
