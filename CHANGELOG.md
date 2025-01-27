# Revision history for json-syntax

## 0.2.1.0 -- 2022-03-01

* Support Jackson's SMILE format as an encode target.
* Use `bytebuild`'s `rebuild` function for 2x perf improvement on encode.
* Bump bytebuild for buffer overflow fix.

## 0.2.0.0 -- 2021-03-22

* Switch from `Chunks` to `SmallArray` in the `Object` and `Array` data
  constructors. This makes the library simpler to use but it a breaking
  change.
* Expose `emptyArray` and `emptyObject`.
* Add `object(9|10|11|12)` as convenience helpers for construction.

## 0.1.2.0 -- 2020-11-18

* Add infix pattern synonym for `Member`.
* Add `object(1|2|3|4|5|6|7|8)` as convenience helpers for construction.

## 0.1.1.0 -- 2020-05-01

* Add `encode`.

## 0.1.0.0 -- 2020-01-20

* Initial release.
