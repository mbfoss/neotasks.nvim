class Runner:
    """Minimal task runner used by the demo tests."""

    def __init__(self, tasks, parallel=False):
        self.tasks = list(tasks)
        self.parallel = parallel

    def order(self):
        return list(self.tasks)

    def workers(self):
        # The bug the failing test below reports: a parallel run still uses one
        # worker instead of fanning out across the pool.
        return 1
