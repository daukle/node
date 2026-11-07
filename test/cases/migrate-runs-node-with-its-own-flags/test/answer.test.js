import test from "node:test";
import assert from "node:assert/strict";
import { answer } from "../lib/answer.js";

test("answers", () => assert.equal(answer, 42));
