def cmd_lsns(args, cache):
    for namespace in sorted(cache.get('namespaces', ())):
        print(namespace)
