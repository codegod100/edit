Align and Extend the KV Store in examples/kv_store/:
1. Implement 'FileStore' in file_store.zig. It must parse the 'key:value' format in db.txt.
2. Extend the 'KVStore' interface in interface.zig to include a 'delete' method.
3. Implement 'delete' in FileStore.
4. MEMORY AUDIT: Identify and fix any memory leaks in main.zig (Hint: check return values of 'get').
5. Update main.zig to delete the 'user' key after printing status.
6. Verify with 'zig run examples/kv_store/main.zig'.
7. Reply DONE.