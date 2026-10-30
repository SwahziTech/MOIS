import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/index.css';
import App from './App.jsx';
import { initTheme } from './components/ThemeToggle';
import PwaStatus from './components/PwaStatus';

initTheme();

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
    <PwaStatus />
  </StrictMode>
);
