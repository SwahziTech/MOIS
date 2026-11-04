import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/index.css';
import App from './App.jsx';
import { initTheme } from './components/ThemeToggle';
import PwaStatus from './components/PwaStatus';
import { installFileDrop } from './lib/fileDrop';

initTheme();
installFileDrop();   // drag and drop onto every upload

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
    <PwaStatus />
  </StrictMode>
);
