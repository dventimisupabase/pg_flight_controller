\set cat random(1, 10)
INSERT INTO fix_mixed (category, value, note)
VALUES ('cat-' || :cat, random() * 1000, repeat('n', 50));
