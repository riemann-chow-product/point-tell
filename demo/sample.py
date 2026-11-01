def create_order(user_id, items):
    total = 0
    for it in items:
        total += it["price"] * it["qty"]
    return db.insert("orders", {"user": user_id, "total": total})


def refund(order_id, amount):
    order = db.get("orders", order_id)
    order["total"] -= amount
    db.update("orders", order_id, order)
    return order
