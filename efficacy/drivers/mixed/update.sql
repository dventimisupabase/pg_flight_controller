\set id random(1, :rows)
\set val random(0, 1000)
UPDATE fix_mixed SET value = :val WHERE id = :id;
