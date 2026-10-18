const semver = require("semver");

test("semver is found", () => {
  expect(semver.valid("1.2.3")).toBe("1.2.3");
});
