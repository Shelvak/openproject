worker_processes 2
timeout 60
preload_app false
listen '/tmp/unicorn.openproject.socket', backlog: 1024
working_directory '/home/rotsen/apps/openproject'
pid "tmp/pids/unicorn.pid"

stderr_path "log/unicorn.stderr.log"
stdout_path "log/unicorn.stdout.log"
