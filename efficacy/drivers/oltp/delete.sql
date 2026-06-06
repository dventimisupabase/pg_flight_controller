\set id random(1, :rows)
DELETE FROM fix_oltp WHERE id = :id;
