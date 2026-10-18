sed 's/"private": true/"private": false/' package.json > package.json.edited
mv package.json.edited package.json
grep -q '"private": false' package.json
