const ts=require('typescript');
const fs=require('fs'),path=require('path');
const root=path.resolve(__dirname,'..');
const out=path.join(root,'.test-build');
for(const rel of ['components/macmint/brand.tsx','components/macmint/content.ts','components/macmint/dialog.tsx','components/macmint/feature-demos.tsx','components/macmint/product-demo.tsx','components/macmint/home-page.tsx','lib/product-config.ts']){
 let s=fs.readFileSync(path.join(root,rel),'utf8');
 s=s.replace(/(["'])@\/([^"']+)\1/g,(_,q,p)=>q+path.relative(path.dirname(path.join(out,rel)),path.join(out,p)).replace(/^(?!\.)/,'./')+q);
 const dest=path.join(out,rel.replace(/\.tsx?$/,'.js'));fs.mkdirSync(path.dirname(dest),{recursive:true});
 fs.writeFileSync(dest,ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020,jsx:ts.JsxEmit.ReactJSX,esModuleInterop:true}}).outputText);
}
