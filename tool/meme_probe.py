import sqlite3

con = sqlite3.connect(r'C:\Users\xi283\.dsh\meme-packs\dafeiyu-desktop\index.db')
cur = con.cursor()
cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
tables = [r[0] for r in cur.fetchall()]
print('tables:', tables)
for t in tables:
    cur.execute('PRAGMA table_info(%s)' % t)
    cols = [c[1] for c in cur.fetchall()]
    print(t, '->', cols)
    cur.execute('SELECT COUNT(*) FROM %s' % t)
    print('   rows:', cur.fetchone()[0])

# sample a few rows from the main table
for t in tables:
    print('--- sample', t)
    try:
        cur.execute('SELECT * FROM %s LIMIT 3' % t)
        for row in cur.fetchall():
            print('   ', row)
    except Exception as exc:
        print('   failed:', exc)
