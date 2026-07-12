// Demonstra paralelismo real no wasm: cada `spawn` roda num Web Worker que
// compartilha a memória linear. Resultados pequenos (o ABI do thunk é i32).
function work(base: i64, n: i64): i64 {
  let s: i64 = 0
  for (let i: i64 = 0; i < n; i = i + 1) {
    s = s + base
  }
  return s
}

function main(): i32 {
  const a = spawn work(2, 1000)   // 2000
  const b = spawn work(3, 1000)   // 3000
  const c = spawn work(5, 1000)   // 5000
  const ra: i64 = join(a)
  const rb: i64 = join(b)
  const rc: i64 = join(c)
  const total: i64 = ra + rb + rc // 10000
  Terminal.log(`ra=${ra} rb=${rb} rc=${rc} total=${total}`)
  return total - 10000            // 0 se tudo certo
}
