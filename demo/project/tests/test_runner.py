from src.runner import Runner


def test_depends_on():
    runner = Runner(["build", "test"])
    assert runner.order() == ["build", "test"]


def test_parallel():
    runner = Runner(["a", "b", "c"], parallel=True)
    # The pool is meant to fan the three tasks out across three workers.
    assert runner.workers() == 3
