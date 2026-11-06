from app import add


def test_add():
    assert add(1, 2) == 3


def test_add_wrong():
    assert add(1, 1) == 3
