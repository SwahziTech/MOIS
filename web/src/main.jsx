import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/index.css';
import App from './App.jsx';
import { initTheme } from './components/ThemeToggle';
import PwaStatus from './components/PwaStatus';
import { installFileDrop } from './lib/fileDrop';
import { installNameCaps } from './lib/nameCaps';
import { installSuggest } from './lib/suggest';
import { installPhoneCards } from './lib/phoneCards';

initTheme();
installFileDrop();   // drag and drop onto every upload
installNameCaps();   // names start with capitals as they are typed (2026-11-11)
installSuggest();    // suggestions drop down right under their box (2026-11-11)
installPhoneCards(); // list tables read as cards on phones (2026-11-23)

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
    <PwaStatus />
  </StrictMode>
);
