const isOdd = require("is-odd");
const isBuffer = require("is-buffer");
console.log("odd", isOdd(3), "buffer", isBuffer(Buffer.alloc(1)));
