import { writeFileSync } from 'node:fs';
const origin = new URL(process.env.NEXT_PUBLIC_SITE_URL || 'https://macmint.co').origin;
writeFileSync(new URL('../public/robots.txt', import.meta.url), `User-agent: *\nAllow: /\nSitemap: ${origin}/sitemap.xml\n`);
writeFileSync(new URL('../public/sitemap.xml', import.meta.url), `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${origin}/</loc></url></urlset>\n`);
