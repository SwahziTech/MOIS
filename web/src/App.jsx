import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider } from './hooks/useAuth';
import { ProtectedLayout, AuthLayout } from './components/Layout';
import Login        from './pages/auth/Login';
import Signup       from './pages/auth/Signup';
import ForgotPassword from './pages/auth/ForgotPassword';
import ResetPassword  from './pages/auth/ResetPassword';
import Dashboard    from './pages/Dashboard';
import Products     from './pages/Products';
import Materials    from './pages/Materials';
import Branches     from './pages/Branches';
import UsersPage    from './pages/Users';
import Recipes      from './pages/Recipes';
import Pricing      from './pages/Pricing';
import Settings     from './pages/Settings';

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          {/* Auth routes (redirect to / if already signed in) */}
          <Route element={<AuthLayout />}>
            <Route path="/login"           element={<Login />} />
            <Route path="/signup"          element={<Signup />} />
            <Route path="/forgot-password" element={<ForgotPassword />} />
            <Route path="/reset-password"  element={<ResetPassword />} />
          </Route>

          {/* Protected routes (redirect to /login if not signed in) */}
          <Route element={<ProtectedLayout />}>
            <Route index               element={<Dashboard />} />
            <Route path="/products"    element={<Products />} />
            <Route path="/materials"   element={<Materials />} />
            <Route path="/branches"    element={<Branches />} />
            <Route path="/users"       element={<UsersPage />} />
            <Route path="/recipes"     element={<Recipes />} />
            <Route path="/pricing"     element={<Pricing />} />
            <Route path="/settings"    element={<Settings />} />
          </Route>

          {/* Catch-all */}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}
