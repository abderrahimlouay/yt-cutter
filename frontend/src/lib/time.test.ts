import { describe, expect, it } from "vitest";
import { formatTime, parseTime } from "./time";

describe("formatTime", () => {
  it("formats minutes and seconds", () => {
    expect(formatTime(0)).toBe("0:00");
    expect(formatTime(65)).toBe("1:05");
    expect(formatTime(600)).toBe("10:00");
  });
  it("formats hours", () => {
    expect(formatTime(3723)).toBe("1:02:03");
  });
  it("never goes negative", () => {
    expect(formatTime(-5)).toBe("0:00");
  });
});

describe("parseTime", () => {
  it("parses plain seconds", () => {
    expect(parseTime("90")).toBe(90);
    expect(parseTime(" 12.5 ")).toBe(12.5);
  });
  it("parses mm:ss and hh:mm:ss", () => {
    expect(parseTime("1:30")).toBe(90);
    expect(parseTime("90:00")).toBe(5400);
    expect(parseTime("1:02:03")).toBe(3723);
  });
  it("rejects invalid input", () => {
    for (const bad of ["", "abc", "-5", "1:75", "1:2:3:4", "1.5:30", "1::2", ":"]) {
      expect(parseTime(bad)).toBeNull();
    }
  });
});
