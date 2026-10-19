const React=require('react');const {create,act}=require('react-test-renderer');const assert=require('node:assert/strict');
global.IS_REACT_ACT_ENVIRONMENT=true;
const listeners={};global.document={addEventListener(name,handler){listeners[name]=handler},removeEventListener(name){delete listeners[name]},activeElement:{focus(){}},body:{style:{overflow:''}},getElementById(){return null},querySelector(){return null}};
const {HomePage}=require('../.test-build/components/macmint/home-page');
const {ProductDemo}=require('../.test-build/components/macmint/product-demo');
const {DuplicateDemo,LargeFilesDemo,UninstallerDemo}=require('../.test-build/components/macmint/feature-demos');
const text=n=>Array.isArray(n)?n.map(text).join(''):typeof n==='string'?n:!n?'':(n.children||[]).map(text).join('');
let passed=0;const ok=(value,message)=>{assert.ok(value,message);passed++;};
async function mount(C){let tree;await act(async()=>{tree=create(React.createElement(C),{createNodeMock:el=>el.type==='dialog'?{showModal(){},close(){}}:null});});return tree;}
function button(t,label){return t.root.findAllByType('button').find(b=>text(b).includes(label));}
async function click(b){assert.ok(b,'Button exists');await act(async()=>b.props.onClick());}
(async()=>{
 const home=await mount(HomePage);
 const ids=home.root.findAll(n=>typeof n.type==='string'&&n.props.id).map(n=>n.props.id);
 const links=home.root.findAllByType('a').map(n=>n.props.href).filter(s=>s?.startsWith('#')&&s!=='#');
 ok(links.every(h=>ids.includes(h.slice(1))),'Every navigation anchor has a target');
 ok(home.root.findAllByType('h1').length===1,'One semantic h1');
 ok(home.root.findAllByType('details').length>=10,'FAQ and disclosure markup exists');
 const menu=home.root.findAllByType('button').find(n=>n.props['aria-controls']==='mobile-nav');await click(menu);ok(menu.props['aria-expanded']===true,'Mobile menu opens');await act(async()=>listeners.keydown({key:'Escape'}));ok(menu.props['aria-expanded']===false,'Mobile menu closes on Escape');
 await click(button(home,'Get MacMint'));ok(home.root.findAllByType('dialog').length===1,'CTA opens availability dialog');ok(text(home.toJSON()).includes('isn’t available yet'),'No fake download claim');await click(home.root.findAllByType('button').find(n=>n.props['aria-label']==='Close dialog'));

 ok(text(home.toJSON()).includes('In development · No installer available yet.'),'Release state is disclosed beside CTAs');
 const workflowTabs=home.root.findAllByType('button').filter(n=>n.props.id?.startsWith('step-tab-'));
 let prevented=false;await act(async()=>workflowTabs[0].props.onKeyDown({key:'ArrowRight',preventDefault(){prevented=true}}));
 ok(prevented&&workflowTabs[1].props['aria-selected']===true,'Workflow supports keyboard arrow navigation');
 ok(home.root.find(n=>n.props.id==='step-panel').props['aria-labelledby']==='step-tab-1','Workflow panel follows accessible tab label');
 await click(home.root.findAllByType('a').find(n=>text(n).includes('Explore startup inventory')));
 ok(home.root.findByType(ProductDemo).props.module==='startup','Utility shortcut selects the controlled demo directly');
 await click(home.root.findAllByType('a').find(n=>text(n).includes('Explore the live demo')));
 ok(home.root.findByType(ProductDemo).props.module==='overview','Final demo action resets the module to Smart Scan');
 const prod=await mount(ProductDemo);await click(button(prod,'Run Smart Scan'));ok(text(prod.toJSON()).includes('Scanning…'),'Scan starts');await click(button(prod,'Cancel'));ok(text(prod.toJSON()).includes('Demo scan cancelled'),'Scan cancels');
 const picker=prod.root.findAllByType('select').find(n=>n.props['aria-label']==='Choose a product demo');
 ok(picker.findAllByType('option').length===8,'Phone demo selector exposes all eight modules');
 await act(async()=>picker.props.onChange({target:{value:'cleaner'}}));
 const search=prod.root.findAllByType('input').find(n=>n.props['aria-label']==='Search example cleanup items');
 await act(async()=>search.props.onChange({target:{value:'no matching files'}}));
 ok(text(prod.toJSON()).includes('No example items match'),'Cleanup search gives an explicit empty state');
 await click(button(prod,'Clear filters'));ok(prod.root.findAll(n=>n.props.className==='cleanup-row').length===5,'Clear filters restores all cleanup results');
 await act(async()=>picker.props.onChange({target:{value:'overview'}}));
 let backup=prod.root.findAllByType('input').find(n=>n.props.type==='checkbox'&&n.props.checked===false);ok(!!backup,'Review items start unchecked');await act(async()=>backup.props.onChange());ok(text(prod.toJSON()).includes('Review 7.6 GB'),'Selected totals update');
 await click(button(prod,'Review 7.6 GB'));ok(text(prod.toJSON()).includes('including 1.2 GB of review items'),'Confirmation calls out review data');await click(button(prod,'Move to demo Trash'));ok(text(prod.toJSON()).includes('Example cleanup complete'),'Demo cleanup removes selected example rows');await click(button(prod,'History'));ok(text(prod.toJSON()).includes('7.6 GB moved to demo Trash'),'Demo history records cleanup');
 const dup=await mount(DuplicateDemo);await click(button(dup,'Verify example files'));await click(button(dup,'Select extra copies'));const files=dup.root.findAllByType('button').filter(n=>n.props.className?.includes('duplicate-file'));await click(files[0]);ok(text(dup.toJSON()).includes('At least one copy must remain'),'Final-copy protection enforced');ok(files.filter(n=>n.props['aria-pressed']).length===2,'Only two copies selected');await click(button(dup,'Demo Trash'));ok(text(dup.toJSON()).includes('One copy remains'),'Duplicate cleanup leaves a keeper');
 const large=await mount(LargeFilesDemo);const select=large.root.findByType('select');await act(async()=>select.props.onChange({target:{value:'5'}}));ok(large.root.findAll(n=>n.props.className==='file-row').length===1,'5 GB threshold filters files');await click(large.root.findAllByType('button').find(n=>n.props['aria-label']==='Review Weekend-film.mov'));ok(text(large.toJSON()).includes('This only changes the example'),'Large file removal requires review');await click(button(large,'Move to demo Trash'));ok(text(large.toJSON()).includes('No example files match'),'Reviewed file is removed from example');
 const uninstall=await mount(UninstallerDemo);await click(button(uninstall,'Orbit Notes'));ok(text(uninstall.toJSON()).includes('0.98 GB'),'Uninstaller total follows app and selected related files');await click(button(uninstall,'Review uninstall'));await click(button(uninstall,'Confirm demo uninstall'));ok(text(uninstall.toJSON()).includes('Example app moved to Trash'),'Uninstaller confirmation works');
 for(const t of [home,prod,dup,large,uninstall])await act(async()=>t.unmount());
 console.log(`PASS: ${passed} checks covering navigation, keyboard workflow, mobile module selection, release clarity, empty-state recovery, scan cancellation, review defaults, cleanup, history, duplicate keeper safety, file filters and uninstall.`);
})().catch(e=>{console.error(e);process.exit(1)});
