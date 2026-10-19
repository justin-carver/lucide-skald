// Regenerates golden/*.png: each fixture rendered by resvg at 24px width.
//   npm install @resvg/resvg-js@2.6.2 && node gen_golden.mjs
import { Resvg } from "@resvg/resvg-js";
import { readdirSync, readFileSync, writeFileSync } from "node:fs";

for (const file of readdirSync(".").filter((f) => f.endsWith(".svg"))) {
  const png = new Resvg(readFileSync(file), { fitTo: { mode: "width", value: 24 } }).render().asPng();
  writeFileSync(`golden/${file.replace(/\.svg$/, ".png")}`, png);
}
