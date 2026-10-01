// Lee las carpetas públicas de Google Drive y genera comunicados.json
// (nombre, fecha de modificación e id de cada archivo) para la sección Comunicados.
// Lo ejecuta la tarea de GitHub "Actualizar comunicados"; también se puede correr a mano: node scripts/actualizar-comunicados.mjs
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const carpetas = JSON.parse(readFileSync("comunicados.carpetas.json", "utf8"));
const decodificar = t => t.replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n)).replace(/&quot;/g, '"').replace(/&#39;/g, "'")
  .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

const salida = [];
for (const c of carpetas) {
  const res = await fetch(`https://drive.google.com/embeddedfolderview?id=${c.carpeta}&hl=es`, { headers: { "Accept-Language": "es-CL,es;q=0.9" } });
  if (!res.ok) throw new Error(`No se pudo leer la carpeta "${c.nombre}": HTTP ${res.status}`);
  const html = await res.text();
  const archivos = [];
  for (const bloque of html.split('<div class="flip-entry" ').slice(1)) {
    const id = bloque.match(/^id="entry-([\w-]+)"/)?.[1];
    const titulo = bloque.match(/class="flip-entry-title">([^<]*)</)?.[1];
    if (!id || titulo == null) continue;
    const fecha = bloque.match(/class="flip-entry-last-modified"><div>([^<]*)</)?.[1] ?? "";
    const tipo = /href="https:\/\/drive\.google\.com\/drive\/folders\//.test(bloque) ? "carpeta" : "archivo";
    archivos.push({ id, titulo: decodificar(titulo), fecha: decodificar(fecha), tipo });
  }
  salida.push({ nombre: c.nombre, carpeta: c.carpeta, archivos });
  console.log(`${c.nombre}: ${archivos.length} archivos`);
}

const nuevo = JSON.stringify(salida, null, 1) + "\n";
const anterior = existsSync("comunicados.json") ? readFileSync("comunicados.json", "utf8") : "";
if (nuevo === anterior) console.log("Sin cambios.");
else { writeFileSync("comunicados.json", nuevo); console.log("comunicados.json actualizado."); }
