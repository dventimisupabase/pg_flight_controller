\set id random(1, :rows)
\set balance random(0, 10000)
UPDATE fix_oltp SET balance = :balance, updated = now() WHERE id = :id;
