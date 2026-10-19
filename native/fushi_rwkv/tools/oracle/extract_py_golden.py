import ast
import json
import sys

src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src)
out = {}
for node in tree.body:
    if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
        name = node.targets[0].id
        if name.startswith("_RWKV_GOLDEN") or name == "_RWKV_ABS_TOL":
            out[name] = ast.literal_eval(node.value)
json.dump(out, open(sys.argv[2], "w"), indent=1)
print(len(out["_RWKV_GOLDEN_REVIEWS"]), {k: v for k, v in out.items() if k != "_RWKV_GOLDEN_REVIEWS"})
